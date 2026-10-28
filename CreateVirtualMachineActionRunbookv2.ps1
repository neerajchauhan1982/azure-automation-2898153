#Created By: Neeraj Kumar
#Date: December 2020 (updated October 2026 for Az / PowerShell 7.4 / user-assigned identity)
#Called by InitateWatchProcess - creates one VM from the parameters passed.

param(
    [string[]] $vmdetail,
    [string]   $SubscriptionId
)
$ErrorActionPreference = 'Stop'
Write-Output "Runbook: CreateVirtualMachineActionRunbook  PS: $($PSVersionTable.PSVersion)"

# Sign in with the user-assigned identity
$clientId = Get-AutomationVariable -Name 'automationUserID'
Connect-AzAccount -Identity -AccountId $clientId | Out-Null
if ($SubscriptionId) { Set-AzContext -Subscription $SubscriptionId | Out-Null }

$global:vnet       = Get-AutomationVariable -Name 'Vnet'
$global:NSGName    = Get-AutomationVariable -Name 'nsg'
$global:subnetname = ''
$global:subnetid   = ''

# Pick a subnet with free IPs, or create the next /24 if all are full
function Get-Subnet {
    $VNET = Get-AzVirtualNetwork -Name $global:vnet
    foreach ($Subnet in $VNET.Subnets) {
        $mask      = [int]($Subnet.AddressPrefix -split '/')[1]
        $available = [math]::Pow(2, 32 - $mask) - 5          # Azure reserves 5 IPs per subnet
        $used      = @($Subnet.IpConfigurations).Count
        if ($available - $used -gt 0) {
            $global:subnetname = $Subnet.Name
            $global:subnetid   = $Subnet.Id
            Write-Output "Using subnet $($Subnet.Name)"
            return
        }
    }

    $last      = $VNET.Subnets[-1].AddressPrefix              # e.g. 10.0.3.0/24
    $octets    = ($last -split '/')[0] -split '\.'
    $newPrefix = "{0}.{1}.{2}.0/24" -f $octets[0], $octets[1], ([int]$octets[2] + 1)
    $newName   = "subnetVM$($VNET.Subnets.Count + 1)"

    Add-AzVirtualNetworkSubnetConfig -Name $newName -VirtualNetwork $VNET -AddressPrefix $newPrefix | Out-Null
    $VNET = $VNET | Set-AzVirtualNetwork
    $new  = $VNET.Subnets | Where-Object Name -eq $newName
    $global:subnetname = $new.Name
    $global:subnetid   = $new.Id
    Write-Output "Created subnet $newName ($newPrefix)"
}

# Create the new virtual machine
function CreateVM ($vmName, $computername, $location, $resourcegroup, $vmLocalAdminUser,
                   $vmLocalAdminPassword, $vmSize, $SKUs, $publisher, $offering) {

    $securePwd  = ConvertTo-SecureString $vmLocalAdminPassword -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential ($vmLocalAdminUser, $securePwd)

    # Skip if the VM already exists
    try { $existing = Get-AzVM -ResourceGroupName $resourcegroup -Name $vmName } catch { $existing = $null }
    if ($existing) { Write-Output "VM $vmName already exists - skipping."; return }

    # Public IP: reuse if it exists, otherwise create
    try { $pip = Get-AzPublicIpAddress -ResourceGroupName $resourcegroup -Name "pip-$vmName" } catch { $pip = $null }
    if (-not $pip) {
        $pip = New-AzPublicIpAddress -ResourceGroupName $resourcegroup -Name "pip-$vmName" `
               -Location $location -AllocationMethod Static -Sku Standard
    }

    $nsgid = (Get-AzNetworkSecurityGroup -Name $global:NSGName -ResourceGroupName $resourcegroup).Id

    # NIC: reuse if it exists, otherwise create
    try { $NIC = Get-AzNetworkInterface -ResourceGroupName $resourcegroup -Name "nic_$vmName" } catch { $NIC = $null }
    if (-not $NIC) {
        $NIC = New-AzNetworkInterface -Name "nic_$vmName" -ResourceGroupName $resourcegroup -Location $location `
               -SubnetId $global:subnetid -NetworkSecurityGroupId $nsgid -PublicIpAddressId $pip.Id
    }

    $vm = New-AzVMConfig -VMName $vmName -VMSize $vmSize
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $computername -Credential $Credential -ProvisionVMAgent
      # Disable automatic updates / Azure-managed patching
    $vm.OSProfile.WindowsConfiguration.EnableAutomaticUpdates = $false
    if (-not $vm.OSProfile.WindowsConfiguration.PatchSettings) {
        $vm.OSProfile.WindowsConfiguration.PatchSettings = [Microsoft.Azure.Management.Compute.Models.PatchSettings]::new()
    }
    $vm.OSProfile.WindowsConfiguration.PatchSettings.PatchMode = "Manual"
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $NIC.Id
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $publisher -Offer $offering -Skus $SKUs -Version latest
    $vm = Set-AzVMBootDiagnostic -VM $vm -Disable

    New-AzVM -ResourceGroupName $resourcegroup -VM $vm -Location $location | Out-Null
    
    Write-Output "VM $vmName created in $resourcegroup ($location)."
}

# Order from Excel: Name, Computername, Location, RGName, LocalAdminUser, Password, Size, PublisherName, OfferName, SKU
Write-Output "Creating VM: $($vmdetail[0])"
Get-Subnet
CreateVM $vmdetail[0] $vmdetail[1] $vmdetail[2] $vmdetail[3] $vmdetail[4] `
         $vmdetail[5] $vmdetail[6] $vmdetail[9] $vmdetail[7] $vmdetail[8]
