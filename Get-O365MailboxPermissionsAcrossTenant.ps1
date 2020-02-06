#Requires -Module ExchangeOnlineManagement,ActiveDirectory
<#
.NOTES
    Created By: Brendan Horner (hornerit.com)
    Purpose: Get all custom permissions entries across the entire tenant and store in csv files
    Version History:
    --2020-02-06-Initial public version. Performance with new EXO modules appears to be 8-10 hours per 100k mailboxes

.SYNOPSIS
Obtains all custom mailbox permissions for the entire tenant with some options to reduce the scope as necessary
.DESCRIPTION
Obtains all mailboxes, only recently changed mailboxes, or resumes previous efforts
.PARAMETER NoMFA
[OPTIONAL] If you know for certain that MFA is not enabled on your tenant or for the account under which you wish to run this, use this switch. No value is expected.
.PARAMETER CustomPermsCSVPath
[REQUIRED] CSV output path and name where the output needs to go (and temp and other files will be generated within the same folder). Defaults to the current script folder\CustomPermEntriesForMailboxes.csv"
.PARAMETER GetMailboxResultSize
[OPTIONAL] If you are testing, use a number here to reduce overall query size. Defaults to "Unlimited" for entire tenant
.PARAMETER ProcessNewlyCreatedOrChangedMailboxesOnly
[OPTIONAL] To reduce the overall download, use this switch to check the full download file and download only items changed 24 hours earlier than either the created or modified date of the full download CSV, whichever is earliest
.PARAMETER IncludeFolders
[OPTIONAL] If mailbox folder permissions wish to be downloaded, set this value to $true
.PARAMETER Resume
[OPTIONAL] If this script was interrupted or errored previously (preferably very recently ONLY), use this switch to resume the download and be sure to add -IncludeFolders $true if you intended to run this for folders and the Modified switch if you remember setting that. If the interruption was more than 1 week, do not use this switch - just download the full dataset.
.PARAMETER UseModifiedDateForPermsDelta
[OPTIONAL] If using the ProcessNewlyCreatedOrChangedMailboxesOnly switch, this switch forces the use of the modified date instead of the created date for determining how far back to retrieve permissions. This is sometimes required due to overwriting files keeping old created date.
#>
[CmdletBinding()]
param(
    [switch]$NoMFA,
    [string]$CustomPermsCSVPath = "$PSScriptRoot\CustomPermEntriesForMailboxes.csv",
    [string]$GetMailboxResultSize = "Unlimited",
    [string]$EmailDomain = "@contoso.com",
    [switch]$ProcessNewlyCreatedOrChangedMailboxesOnly,
    [bool]$IncludeFolders,
    [switch]$Resume,
    [switch]$UseModifiedDateForPermsDelta
)
Import-Module ExchangeOnlineManagement
Import-Module ActiveDirectory
#This Test-ObjectId function is needed because sometimes a permissions entry on a mailbox ends up being an Active Directory SID and we need to try to return a user instead.
function Test-ObjectId{
    param([string]$Sid,[string]$DisplayName)
    try {
        if($Sid.Length -gt 0){
            $ADO = Get-ADObject -Filter "objectSid -eq '$Sid'" -Properties UserPrincipalName -ErrorAction Stop
        } else {
            $ADO = Get-ADObject -Filter "displayName -eq '$DisplayName'" -Properties UserPrincipalName -ErrorAction Stop
        }
        if($ADO.UserPrincipalName.Length -gt 0){
            return $ADO.UserPrincipalName
        } else {
            return $ADO.Name
        }
    } catch {
        return $Sid
    }
}

if($EmailDomain -eq "@contoso.com"){
    do{
        $EmailDomain = Read-Host "Please enter your email domain as @yourdomain.com (e.g. @myschool.edu)"
    } until ($EmailDomain.Length -gt 0 -and $EmailDomain -ne "@contoso.com")
}

#Prompt for credential to use and use some validation to make sure it is an Exchange Admin. If using MFA, we don't need a password because the MFA window will ask for it.
do{
    $CredEntry = if(!($NoMFA)){
        New-Object PSCredential((Read-Host "[Required]Email address of Exchange Admin account to use for this script. This prompt will repeat until you supply a valid entry."),(ConvertTo-SecureString " " -AsPlainText -Force))
    } else {
        Get-Credential -UserName (Read-Host "[Required]Email address of Exchange Admin account to use for this script. This prompt will repeat until you supply a valid entry.") -Message "Please enter password"
    }
    #Verify they entered something
    if($CredEntry.UserName.Length -gt 0){
        #Verify they entered an email address using a regex match
        if($CredEntry.UserName -match "^.+@.+\..+$"){
            if(!($NoMFA)){
                Write-Verbose "Attempting to MFA connect $CredEntry"
                Connect-ExchangeOnline -UserPrincipalName $CredEntry.UserName
            } else {
                Write-Verbose "Attempting to connect to O365 and verify this is an Exchange admin"
                Connect-ExchangeOnline -Credential $CredEntry
            }
            try {
                #This command will only work if you are an Exchange Admin
                Get-OrganizationConfig -ErrorAction Stop | Select-Object Name
            } catch {
                Write-Host "There was an error connecting to O365: Not an admin, account cannot use basic auth, bad password, or bad email"
                $CredEntry = $null
            }
        } else {
            Write-Host "That was not a valid entry, try again"
            $CredEntry = $null
        }
    }
} until ($CredEntry.UserName.Length -gt 0)

#Setup and begin logging and start the timer to track the total time to complete the script
$LogPath = "$PSScriptRoot\TranscriptLog-GetTenantMailboxPerms.txt"
Start-Transcript -Path $LogPath -Append
$Timer = [System.Diagnostics.Stopwatch]::StartNew()
$TotalMailboxesProcessed = 0

#Begin processing
Write-Host "Retrieving Mailbox Permissions...current time is $(Get-Date -format g)"
if($ProcessNewlyCreatedOrChangedMailboxesOnly -or $Resume){
    #If we are only trying to handle recent changes, we need the oldest date of the custom permissions entries between its creation and recent modifications (in case you removed an entry or something)
    if((Get-Item -Path $CustomPermsCSVPath).LastWriteTimeUtc -le ((Get-Item -Path $CustomPermsCSVPath).CreationTimeUtc) -or $UseModifiedDateForPermsDelta){
        $DateForDelta = Get-Date (Get-Date (Get-Item -Path $CustomPermsCSVPath).LastWriteTimeUtc).AddHours(-24) -Format u
    } else {
        $DateForDelta = Get-Date (Get-Date (Get-Item -Path $CustomPermsCSVPath).CreationTimeUtc).AddHours(-24) -Format u
    }
}

#Build a message to the user know the time when beginning to request mailboxes so that expectations can be managed and it's obvious how long this has run
$Message = $(Get-Date -format filedatetime)+" Retrieving mailboxes"

#Fundamental logic problem here - if a mailbox has changed recently to have permissions removed, then they simply won't be in the retrieval and there's no way to use the new commands and know enough to remove them from existing permissions entries. Not a horrible problem because it gives extra investigation but it means data is not perfectly accurate.
try {
    if($Resume){
        #We need to know if we are resuming a full download, a recently-changed download, or a previous resume attempt
        $CustomPermsCSVPathNew = ($CustomPermsCSVPath.Substring(0,$CustomPermsCSVPath.LastIndexOf("."))+'-NEW.csv')
        $TempPermsCSVPath = ($CustomPermsCSVPath.Substring(0,$CustomPermsCSVPath.LastIndexOf("."))+'-TEMP.csv')
        $ResumeCSVPath = ""
        $FoldersFoundInFile = $false
        if(Test-Path $TempPermsCSVPath){
            #Reaching here means that we are resuming a previous resume
            $LastEntry = (import-csv $TempPermsCSVPath | Select-Object -Last 1)
            $LastMailbox = $LastEntry.Mailbox
            if($LastEntry.FolderPath.Length -gt 1){
                $FoldersFoundInFile = $true
            }
            #$DateForDelta = Get-Date (Get-Item -Path $TempPermsCSVPath).LastWriteTimeUtc -Format u
            if($FoldersFoundInFile){
                $Message += "`nResuming last download...downloading mailbox folder permissions whose mailbox name attribute is after $LastMailbox and whenChangedUTC attribute after $DateForDelta from $TempPermsCSVPath"
            } else {
                $Message += "`nResuming last download...downloading mailboxes whose name attribute is after $LastMailbox and whenChangedUTC attribute after $DateForDelta from $TempPermsCSVPath.`nPlease note: The previous attempt did not yet have any folder permissions so it is unknown if that was desired. If you did not specify the `$IncludeFolder = `$true then you will need to run this again for folder changes."
            }
            $ResumeCSVPath = $TempPermsCSVPath
        } elseif(Test-Path $CustomPermsCSVPathNew){
            #Reaching here means we are resuming an attempt to only process new mailboxes
            $LastEntry = import-csv $CustomPermsCSVPathNew | Select-Object -Last 1
            $LastMailbox = $LastEntry.Mailbox
            if($LastEntry.FolderPath.Length -gt 1){
                $FoldersFoundInFile = $true
            }
            #$DateForDelta = Get-Date (Get-Item -Path $CustomPermsCSVPathNew).LastWriteTimeUtc -Format u
            if($FoldersFoundInFile){
                $Message += "`nResuming last download...downloading mailbox folder permissions whose mailbox name attribute is after $LastMailbox and whenChangedUTC attribute after $DateForDelta from $CustomPermsCSVPathNew"
            } else {
                $Message += "`nResuming last download...downloading mailboxes whose name attribute is after $LastMailbox and whenChangedUTC attribute after $DateForDelta from $CustomPermsCSVPathNew.`nPlease note: The previous attempt did not yet have any folder permissions so it is unknown if that was desired. If you did not specify the `$IncludeFolder = `$true then you will need to run this again for folder changes."
            }
            $ResumeCSVPath = $CustomPermsCSVPathNew
        } else {
            #Reaching here means that we are resuming an attempt to download all mailboxes and work fresh
            $LastEntry = import-csv $CustomPermsCSVPath | Select-Object -Last 1
            $LastMailbox = $LastEntry.Mailbox
            if($LastEntry.FolderPath.Length -gt 1){
                $FoldersFoundInFile = $true
            }
            if($FoldersFoundInFile){
                $Message += "`nResuming last download...downloading mailbox folder permissions whose mailbox name attribute is after $LastMailbox and whenChangedUTC attribute after $DateForDelta from $CustomPermsCSVPath"
            } else {
                $Message += "`nResuming last download...downloading mailboxes whose name attribute is after $LastMailbox and whenChangedUTC attribute after $DateForDelta from $CustomPermsCSVPath.`nPlease note: The previous attempt did not yet have any folder permissions so it is unknown if that was desired. If you did not specify the `$IncludeFolder = `$true then you will need to run this again for folder changes."
            }
            $ResumeCSVPath = $TempPermsCSVPath
        }
        #Tell the user that we are starting now and what we are doing
        Write-Host $Message
        #Actually go get the mailbox
        if($FoldersFoundInFile){
            try {
                Get-EXOMailbox -Filter "name -gt '$LastMailbox' -and whenChangedUTC -gt '$DateForDelta'" -ResultSize Unlimited -Properties ExternalDirectoryObjectId | Tee-Object -Variable "arrMailboxes" | Get-EXOMailboxFolderPermission | Where-Object { $_.AccessRights -ne "None" -and @("NT AUTHORITY\SELF") -notcontains $_.User -and $_.User -ne ($_.Identity+"$EmailDomain")} | Select-Object @{Label="Mailbox";Expression={$_.Identity}},@{Label="FolderPath";Expression={$_.FolderName}},@{Label="UserGivenAccess";Expression={if($_.User -like "S-1-5-21-*"){Test-ObjectId -Sid $_.User}else{Test-ObjectId -DisplayName $_.User}}},@{Label="AccessRights";Expression={$_.AccessRights -join ","}} | Export-CSV -Path $ResumeCSVPath -Append
                $TotalMailboxesProcessed += $arrMailboxes.Count
                Remove-Variable -Name "arrMailboxes"
            } catch {
                throw
            }
        } else {
            try {
                Get-EXOMailbox -Filter "name -gt '$LastMailbox' -and whenChangedUTC -gt '$DateForDelta'" -ResultSize Unlimited -Properties ExternalDirectoryObjectId | Tee-Object -Variable "arrMailboxes" | Get-EXOMailboxPermission -ExternalDirectoryObjectId $_.ExternalDirectoryObjectId -ResultSize Unlimited | Where-Object { $_.IsInherited -eq $false -and $_.Deny -eq $false -and @("NT AUTHORITY\SELF") -notcontains $_.User -and $_.User -ne ($_.Identity+"$EmailDomain")} | Select-Object @{Label="Mailbox";Expression={$_.Identity}},@{Label="FolderPath";Expression={''}},@{Label="UserGivenAccess";Expression={if($_.User -like "S-1-5-21-*"){Test-ObjectId -Sid $_.User}else{$_.User}}},@{Label="AccessRights";Expression={$_.AccessRights -join ","}} | Export-CSV -Path $ResumeCSVPath -Append
                $TotalMailboxesProcessed += $arrMailboxes.Count
                Remove-Variable -Name "arrMailboxes"
            } catch {
                throw
            }
            if($IncludeFolders){
                try {
                    Get-EXOMailbox -Filter "whenChangedUTC -gt '$DateForDelta'" -ResultSize Unlimited -Properties ExternalDirectoryObjectId | Tee-Object -Variable "arrMailboxes" | Get-EXOMailboxFolderPermission | Where-Object { $_.AccessRights -ne "None" -and @("NT AUTHORITY\SELF") -notcontains $_.User -and $_.User -ne ($_.Identity+"$EmailDomain")} | Select-Object @{Label="Mailbox";Expression={$_.Identity}},@{Label="FolderPath";Expression={$_.FolderName}},@{Label="UserGivenAccess";Expression={if($_.User -like "S-1-5-21-*"){Test-ObjectId -Sid $_.User}else{Test-ObjectId -DisplayName $_.User}}},@{Label="AccessRights";Expression={$_.AccessRights -join ","}} | Export-CSV -Path $ResumeCSVPath -Append
                    $TotalMailboxesProcessed += $arrMailboxes.Count
                    Remove-Variable -Name "arrMailboxes"
                } catch {
                    throw
                }
            }
        }

        #Since we are resuming, there were some changes recently and so we need to deduplicate the results and create a final product, then remove the temp stuff
        $NewEntries = (Import-CSV $ResumeCSVPath).Mailbox | Select-Object -Unique
        @(Import-CSV $ResumeCSVPath) + @(if(Test-Path $CustomPermsCSVPathNew){Import-CSV $CustomPermsCSVPathNew | Where-Object { $NewEntries -notcontains $_.Mailbox}}) | Sort-Object -Property Mailbox | Export-CSV $CustomPermsCSVPath -Force
        Remove-Item $TempPermsCSVPath -Force -Confirm:$false
        if(Test-Path $CustomPermsCSVPathNew){
            Remove-Item $CustomPermsCSVPathNew
        }
    } elseif($ProcessNewlyCreatedOrChangedMailboxesOnly){
        #Tell the user that we are starting now and what we are doing
        $Message += " Since $DateForDelta (UTC)"
        Write-Host $Message
        #Create a file called NEW to indicate this is only recently changed data. Once we get the NEW data, we deduplicate and merge into the main list of perms entries and then remove the NEW file since it was temporary
        $CustomPermsCSVPathNew = ($CustomPermsCSVPath.Substring(0,$CustomPermsCSVPath.LastIndexOf("."))+'-NEW.csv')
        try {
            Get-EXOMailbox -Filter "whenChangedUTC -gt '$DateForDelta'" -ResultSize $GetMailboxResultSize -Properties ExternalDirectoryObjectId | Tee-Object -Variable "arrMailboxes" | Get-EXOMailboxPermission -ExternalDirectoryObjectId $_.ExternalDirectoryObjectId -ResultSize Unlimited | Where-Object { $_.IsInherited -eq $false -and $_.Deny -eq $false -and @("NT AUTHORITY\SELF") -notcontains $_.User -and $_.User -ne ($_.Identity+"$EmailDomain")} | Select-Object @{Label="Mailbox";Expression={$_.Identity}},@{Label="FolderPath";Expression={''}},@{Label="UserGivenAccess";Expression={if($_.User -like "S-1-5-21-*"){Test-ObjectId -Sid $_.User}else{$_.User}}},@{Label="AccessRights";Expression={$_.AccessRights -join ","}} | Export-CSV -Path $CustomPermsCSVPathNew -Append
            $TotalMailboxesProcessed += $arrMailboxes.Count
        } catch {
            throw
        }
        if($IncludeFolders){
            try{
                $arrMailboxes | Get-EXOMailboxFolderPermission | Where-Object { $_.AccessRights -ne "None" -and @("NT AUTHORITY\SELF") -notcontains $_.User -and $_.User -ne ($_.Identity+"$EmailDomain")} | Select-Object @{Label="Mailbox";Expression={$_.Identity}},@{Label="FolderPath";Expression={$_.FolderName}},@{Label="UserGivenAccess";Expression={if($_.User -like "S-1-5-21-*"){Test-ObjectId -Sid $_.User}else{Test-ObjectId -DisplayName $_.User}}},@{Label="AccessRights";Expression={$_.AccessRights -join ","}} | Export-CSV -Path $CustomPermsCSVPathNew -Append
                $TotalMailboxesProcessed += $arrMailboxes.Count
            } catch {
                throw
            }
        } else {
            Remove-Variable -Name "arrMailboxes"
        }
        #Since we are resuming, there were some changes recently and so we need to deduplicate the results and create a final product, then remove the temp stuff
        $NewEntries = (Import-CSV $CustomPermsCSVPathNew).Mailbox | Select-Object -Unique
        @(Import-CSV $CustomPermsCSVPathNew) + @(Import-Csv $CustomPermsCSVPath | Where-Object { $NewEntries -notcontains $_.Mailbox }) | Sort-Object -Property Mailbox | Export-CSV $CustomPermsCSVPath -Force
        Remove-Item $CustomPermsCSVPathNew -Force
    } else {
        Write-Host $Message
        try {
            Get-EXOMailbox -ResultSize $GetMailboxResultSize -Properties ExternalDirectoryObjectId | Tee-Object -Variable "arrMailboxes" | Get-EXOMailboxPermission $_.ExternalDirectoryObjectId -ResultSize Unlimited | Where-Object { $_.IsInherited -eq $false -and $_.Deny -eq $false -and @("NT AUTHORITY\SELF") -notcontains $_.User -and $_.User -ne ($_.Identity+"$EmailDomain")} | Select-Object @{Label="Mailbox";Expression={$_.Identity}},@{Label="FolderPath";Expression={''}},@{Label="UserGivenAccess";Expression={if($_.User -like "S-1-5-21-*"){Test-ObjectId -Sid $_.User}else{$_.User}}},@{Label="AccessRights";Expression={$_.AccessRights -join ","}} | Export-CSV -Path $CustomPermsCSVPath -Force
            $TotalMailboxesProcessed += $arrMailboxes.Count
        } catch {
            throw
        }
        if($IncludeFolders){
            try{
                $arrMailboxes | Get-EXOMailboxFolderPermission | Where-Object { $_.AccessRights -ne "None" -and @("NT AUTHORITY\SELF") -notcontains $_.User -and $_.User -ne ($_.Identity+"$EmailDomain")} | Select-Object @{Label="Mailbox";Expression={$_.Identity}},@{Label="FolderPath";Expression={$_.FolderName}},@{Label="UserGivenAccess";Expression={if($_.User -like "S-1-5-21-*"){Test-ObjectId -Sid $_.User}else{Test-ObjectId -DisplayName $_.User}}},@{Label="AccessRights";Expression={$_.AccessRights -join ","}} | Export-CSV -Path $CustomPermsCSVPath -Append
                $TotalMailboxesProcessed += $arrMailboxes.Count
                Remove-Variable -Name "arrMailboxes"
            } catch {
                throw
            }
        }
    }
} catch {
    Write-Host "Error - $_"
    Read-Host "$now - The command to get mailboxes or permissions stopped due to error. Sorry about that"
    Get-PSSession | Remove-PSSession
    exit
}
Get-PSSession | Remove-PSSession
$Timer.Stop()
Write-host "Done, the runtime for this entire process was"($timer.Elapsed.TotalMinutes)"minutes. Total Mailboxes processed (whether mailboxes, folders, or both): $TotalMailboxesProcessed"
Stop-Transcript
Read-Host "Press any key to exit"
exit