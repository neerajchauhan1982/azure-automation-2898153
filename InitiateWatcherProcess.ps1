#Created By: Neeraj Kumar
#Date: December 2020
#This script will read the excel file uploaded to the storage account and will extract the values one row at a time.
#and passes it on to another PowerShell script for the purpose of VM creation.
Write-Output "Runbook: $($MyInvocation.MyCommand.Name)  PS: $($PSVersionTable.PSVersion)"

$TenantID = Get-AutomationVariable -Name 'TenantID'

$clientId = Get-AutomationVariable -Name 'UAMIClientId'
Connect-AzAccount -Identity -AccountId $clientId | Out-Null
Write-Output "Signed in as: $((Get-AzContext).Account.Id)"

$vResourceGroupname = "LinkndInLearningAutomation"
$vAutomationAccountName = "LinkdInAccount"
$vaStorageAccount = Get-AutomationVariable -Name "StorageAccount"


$StartTime = Get-Date
$EndTime = $startTime.AddHours(1.0)
$stgAccount = Get-AzStorageAccount -Name $vaStorageAccount -ResourceGroupName $vResourceGroupname
$SASToken = New-AzStorageAccountSASToken -Service 'Blob' -ResourceType Container,Object -Permission "racwdlup" -startTime $StartTime -ExpiryTime $EndTime -Context $stgAccount.Context
$stgcontext = New-AzStorageContext -storageAccountName $stgAccount.StorageAccountName -SasToken $SASToken

  
#try {Import-Module ImportExcel} catch {throw ; return}

$Path = "$env:TEMP\VMDetails.xlsx"
Remove-Item $Path -ErrorAction SilentlyContinue

$blob = Get-AzStorageBlob -Container 'createvm' -Blob 'CreateVM.xlsx' -Context $stgcontext
$tmp = Get-AzStorageBlobContent -CloudBlob $blob.ICloudBlob -Destination $Path -Context $stgcontext #.Context.FileEndPoint + "atcslfileshare"

#import-module psexcel #it wasn't auto loading on my machine

#$details = new-object System.Collections.ArrayList
$ExcelValue = Import-Excel -Path $Path -WorksheetName 'vmcreate' -StartRow 1 -StartColumn 1
#$Data = $ExcelValue | ConvertTo-Json
foreach ($vmdetail in $ExcelValue) {
    if (-not $vmdetail.Name) { continue }   # skip blank rows

    $VMParameter = @(
        [string]$vmdetail.Name,
        [string]$vmdetail.Computername,
        [string]$vmdetail.Location,
        [string]$vmdetail.RGName,
        [string]$vmdetail.LocalAdminUser,
        [string]$vmdetail.Password,
        [string]$vmdetail.Size,
        [string]$vmdetail.PublisherName,
        [string]$vmdetail.OfferName,
        [string]$vmdetail.SKU
    )

    $job = Start-AzAutomationRunbook `
        -ResourceGroupName 'LinkndInLearningAutomation' `
        -AutomationAccountName 'LinkdInAccount' `
        -Name 'CreateVirtualMachineActionRunbook' `
        -Parameters @{ vmdetail = $VMParameter; SubscriptionId = (Get-AzContext).Subscription.Id }

    Write-Output "Started job $($job.JobId) for VM $($vmdetail.Name)"
}
