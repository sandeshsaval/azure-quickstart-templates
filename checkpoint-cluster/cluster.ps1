#############################################################################
# Parameters
#############################################################################
# Description : Name of the resource group to create
# Mandatory   : Yes
$ResourceGroup = "ABFSGAZFW"

# Description : The above SPN password used by the cluster to make API calls
# Mandatory   : Yes
$ClusterPassword = [System.Web.Security.Membership]::GeneratePassword(20, 10)

# Description : Azure location (e.g. eastus2)
# Mandatory   : Yes
$Location = "Central India"
# Description : The Subscription ID to use in case you have more than one
# Mandatory   : No
$SubscriptionId = "0e01f590-5459-4349-b165-111906095afd"
# Description : The Name of storage account to create
# Mandatory   : Yes
# Valid values: Globally unique, 3-24 lower case alphanumeric characters.
$StorageAccount = "ABFSGAZFW02"

# SSH settings, set one of the following
# Description : The Administrator password
# Mandatory   : Only if not provoding an SSH public key
$SSHPassword = "admin@123"
# Description : The Administrator SSH public key (if using SSH public key authentication)
# Mandatory   : Only if not providing an SSH password
$SSHPublicKey = ""

# Description :
# Secure Internal Communication (SIC) one time key used to establish initial
# trust between the gateway and its management server.
# Mandatory   : Yes
$SicKey = "1024"

# Description : The name of the Virtual Network to create
# Mandatory   : Yes
$VNetName = "abfsgvnet002"

# Description : The address range of the Virtual Network to create
# Mandatory   : Yes
# Valid values: CIDR notation
$AddressPrefix = "10.23.220.0/27"

# Description : The names of the subnets to create
# Mandatory   : Yes
$Subnet1Name = "ABFSGFWDMZ"

# Description : The address prefix of each subnet
# Mandatory   : Yes
# Valid values: CIDR notation
$Subnet1Prefix = "10.23.220.0/27"

# Description : Cluster members IP private addresses
# Mandatory   : Yes
# Valid values: A list of IPv4 address
$Subnet1PrivateAddresses = @("10.23.220.5", "10.23.220.10")

# Description : The Cluster name
# Mandatory   : Yes
# Valid values: Must begin with a lower case letter and consist only of lower case letters and numbers.
$ClusterName = "ABFSGAZFWCLUST"

# Description : The size of the VMs of the cluster members
# Mandatory   : Yes
$ClusterVMSize = "Standard_D3_v2"

# Description : A list of web application to create
# Mandatory   : No
# Description : The licensing model
# Mandatory   : Yes
# Valid values:  "sg-byol" - for Bring Your Own License
#                "sg-ngtp" - for a Pay-As-You-Go offering
$SKU = "sg-byol"

#############################################################################
# Variables - these should normally be left unchanged
#############################################################################
$IdleTimeoutInMinutes = 4
$Publisher = "checkpoint"
$Offer = "check-point-r77-10"
$Version = "latest"

# The following services are needed in order to manage the cluster members from an on premise management server
$CheckPointServices = @(
    @{
        "name" = "SSH";
        "protocol" = "tcp";
        "port" = 22
    },
    @{
        "name" = "WebUI";
        "protocol" = "tcp";
        "port" = 443
    },
    @{
        "name" = "FWD";
        "protocol" = "tcp";
        "port" = 256
    },
    @{
        "name" = "CPD";
        "protocol" = "tcp";
        "port" = 18191
    },
    @{
        "name" = "AMON";
        "protocol" = "tcp";
        "port" = 18192
    },
	@{
		"name" = "CPRID";
		"protocol" = "tcp";
		"port" = 18208
	},
    @{
        "name" = "ICAPUSH";
        "protocol" = "tcp";
        "port" = 18211
    }
)

#############################################################################
# Parameter validation
#############################################################################
if (!$ClusterPassword) {
    Throw "Invalid service principal credentials"
}
if (!$SSHPassword -and !$SSHPublicKey) {
    Throw "An SSH password or public key must be specified"
}
if (!$ResourceGroup) {
    Throw "Invalid resource group name"
}
if (!$Location) {
    Throw "Invalid Location"
}

$StorageAccount = $StorageAccount.ToLower()
if (!($StorageAccount -cmatch "^[a-z0-9]*$")) {
    Throw "The StorageAccount should contain only lower case alphanumeric characters"
}
$set    = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
for (; $StorageAccount.Length -lt 24; $x++) {
    $StorageAccount += $set | Get-Random
}

if ($SicKey.Length -lt 8) {
    Throw "SIC key should be at least 8 characters"
}
if (!$ClusterName) {
    Throw "Invalid cluster name"
}
if (!@("sg-byol", "sg-ngtp").Contains($SKU))  {
    Throw "Invalid SKU"
}

#############################################################################
# Resources
#############################################################################

$ErrorActionPreference = "Stop"

# Login:
Add-AzureRmAccount

if ($SubscriptionId) {
	Select-AzureRmSubscription -SubscriptionId $SubscriptionId
} else {
	$SubscriptionId = (Get-AzureRmSubscription)[0].SubscriptionId
}

# Create a new Azure AD application and a service principal
$AppName = "check-point-cluster-"+[guid]::NewGuid()
$azureAdApplication = New-AzureRmADApplication `
    -DisplayName $AppName `
    -HomePage "https://localhost/$AppName" `
    -IdentifierUris "https://localhost/$AppName" `
    -Password $ClusterPassword `
    -EndDate (Get-Date).AddYears(10)

New-AzureRmADServicePrincipal -ApplicationId $azureAdApplication.ApplicationId

# Create a new resource group:
New-AzureRmResourceGroup -Name $ResourceGroup `
    -Location $Location

# Wait till the new application is propagated
Start-Sleep -Seconds 15

# Assign the service with permission to modify the resources in the resource group
New-AzureRmRoleAssignment `
    -ResourceGroupName $ResourceGroup `
    -ServicePrincipalName $azureAdApplication.ApplicationId.Guid `
    -RoleDefinitionName Contributor

$Config = ConvertTo-Json @{
  "debug" =  $false;
  "subscriptionId" = $SubscriptionId;
  "resourceGroup" = $ResourceGroup;
  "credentials" = @{
    "tenant" = (Get-AzureSubscription -Current).TenantId;
    "grant_type" = "client_credentials";
    "client_id" = $azureAdApplication.ApplicationId.Guid;
    "client_secret" = $ClusterPassword;
  };
  "virtualNetwork" = $VNetName;
  "clusterName" = $ClusterName;
  "lbName" = "$ClusterName-LoadBalancer";
}

$CustomData = @"
#!/bin/bash

cat <<EOF >"`$FWDIR/conf/azure-ha.json"
$Config
EOF

conf="install_security_gw=true"
conf="`${conf}&install_ppak=true"
conf="`${conf}&gateway_cluster_member=true"
conf="`${conf}&install_security_managment=false"
conf="`${conf}&ftw_sic_key=$SicKey"

config_system -s "`$conf"
shutdown -r now

"@.replace("`r", "")

# Create the Virtual Network, its subnets and routing tables
$Subnet1RT = New-AzureRmRouteTable `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $Subnet1Name

Add-AzureRmRouteConfig `
    -RouteTable $Subnet1RT `
    -Name "Local-Subnet" `
    -AddressPrefix $Subnet1Prefix `
    -NextHopType VnetLocal | Set-AzureRmRoutetable

Add-AzureRmRouteConfig `
    -RouteTable $Subnet1RT `
    -Name "To-Internal" `
    -AddressPrefix $AddressPrefix `
    -NextHopType VirtualAppliance `
    -NextHopIpAddress $Subnet1PrivateAddresses[0] | Set-AzureRmRoutetable

$Subnet2RT = New-AzureRmRouteTable `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $Subnet2Name

Add-AzureRmRouteConfig `
    -RouteTable $Subnet2RT `
    -Name "Local-Subnet" `
    -AddressPrefix $Subnet2Prefix `
    -NextHopType VnetLocal | Set-AzureRmRoutetable

Add-AzureRmRouteConfig `
    -RouteTable $Subnet2RT `
    -Name "Inside-Vnet" `
    -AddressPrefix $AddressPrefix `
    -NextHopType VirtualAppliance `
    -NextHopIpAddress $Subnet2PrivateAddresses[0] | Set-AzureRmRoutetable

Add-AzureRmRouteConfig `
    -RouteTable $Subnet2RT `
    -Name "To-Internet" `
    -AddressPrefix "0.0.0.0/0" `
    -NextHopType VirtualAppliance `
    -NextHopIpAddress $Subnet2PrivateAddresses[0] | Set-AzureRmRoutetable

$Subnet3RT = New-AzureRmRouteTable `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $Subnet3Name

Add-AzureRmRouteConfig `
    -RouteTable $Subnet3RT `
    -Name "Local-Subnet" `
    -AddressPrefix $Subnet3Prefix `
    -NextHopType VnetLocal | Set-AzureRmRoutetable

Add-AzureRmRouteConfig `
    -RouteTable $Subnet3RT `
    -Name "Inside-Vnet" `
    -AddressPrefix $AddressPrefix `
    -NextHopType VirtualAppliance `
    -NextHopIpAddress $Subnet3PrivateAddresses[0] | Set-AzureRmRoutetable

Add-AzureRmRouteConfig `
    -RouteTable $Subnet3RT `
    -Name "To-Internet" `
    -AddressPrefix "0.0.0.0/0" `
    -NextHopType VirtualAppliance `
    -NextHopIpAddress $Subnet3PrivateAddresses[0] | Set-AzureRmRoutetable

$Subnet1 = New-AzureRmVirtualNetworkSubnetConfig `
    -Name $Subnet1Name `
    -AddressPrefix $Subnet1Prefix `
    -RouteTable $Subnet1RT
$Subnet2 = New-AzureRmVirtualNetworkSubnetConfig `
    -Name $Subnet2Name `
    -AddressPrefix $Subnet2Prefix `
    -RouteTable $Subnet2RT
$Subnet3 = New-AzureRmVirtualNetworkSubnetConfig `
    -Name $Subnet3Name `
    -AddressPrefix $Subnet3Prefix `
    -RouteTable $Subnet3RT

$Vnet = New-AzureRmVirtualNetwork `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $VNetName `
    -AddressPrefix $AddressPrefix `
    -Subnet @($Subnet1, $Subnet2, $Subnet3)
$Subnet1 = Get-AzureRmVirtualNetworkSubnetConfig `
    -VirtualNetwork $Vnet -Name $Subnet1Name
$Subnet2 = Get-AzureRmVirtualNetworkSubnetConfig `
    -VirtualNetwork $Vnet -Name $Subnet2Name
$Subnet3 = Get-AzureRmVirtualNetworkSubnetConfig `
    -VirtualNetwork $Vnet -Name $Subnet3Name


# Create a storage account for storing disks and boot diagnostics
New-AzureRmStorageAccount `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $StorageAccount `
    -Type Standard_LRS

# Create an availability set. We will later place the cluster members in it.
$AvailabilitySet = New-AzureRmAvailabilitySet `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name "$ClusterName-AvailabilitySet"

# Allocate the cluster public address
$ClusterPublicAddress = New-AzureRmPublicIpAddress `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $ClusterName `
    -AllocationMethod Static `
    -IdleTimeoutInMinutes $IdleTimeoutInMinutes

# Create a load balancer
$LoadBalancer = New-AzureRmLoadBalancer `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $ClusterName-LoadBalancer

# Allocate public addresses for the applications
$WebAppsPublicAddresses = @()
foreach ($WebApp in $WebApps) {
    $WebAppPublicAddress = New-AzureRmPublicIpAddress `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -Name $WebApp.name `
        -AllocationMethod Static `
        -IdleTimeoutInMinutes $IdleTimeoutInMinutes
    $WebAppsPublicAddresses += $WebAppPublicAddress

    Add-AzureRmLoadBalancerFrontendIpConfig `
        -Name $WebApp.name `
        -LoadBalancer $LoadBalancer `
        -PublicIpAddress $WebAppPublicAddress
    $IpConfig = $LoadBalancer.FrontendIpConfigurations | where -Property Name -EQ $WebApp.name

    foreach ($Service in $WebApp.services) {
        Add-AzureRmLoadBalancerInboundNatRuleConfig `
            -Name ($WebApp.name + "-" + $Service.name) `
            -LoadBalancer $LoadBalancer `
            -FrontendIpConfiguration $IpConfig `
            -Protocol $Service.protocol `
            -FrontendPort $Service.frontendport `
            -BackendPort $Service.backendport `
            -IdleTimeoutInMinutes $IdleTimeoutInMinutes
    }
}


$MembersPublicAddresses = @()
for ($i = 0; $i -lt 2; $i += 1) {
    $MemberName = $ClusterName + "-" + ($i + 1)
    $MembersPublicAddresses += New-AzureRmPublicIpAddress `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -Name $MemberName `
        -AllocationMethod Static `
        -IdleTimeoutInMinutes $IdleTimeoutInMinutes

    Add-AzureRmLoadBalancerFrontendIpConfig `
        -Name $MemberName `
        -LoadBalancer $LoadBalancer `
        -PublicIpAddress $membersPublicAddresses[$i]
    $IpConfig = $LoadBalancer.FrontendIpConfigurations | where -Property Name -EQ $MemberName

    foreach ($service in $CheckPointServices) {
        Add-AzureRmLoadBalancerInboundNatRuleConfig `
            -Name ("checkpoint-" + $service.name + ($i+1)) `
            -LoadBalancer $LoadBalancer `
            -FrontendIpConfiguration $IpConfig `
            -Protocol $service.protocol `
            -FrontendPort $service.port `
            -BackendPort $service.port `
            -IdleTimeoutInMinutes $IdleTimeoutInMinutes
    }

    $addr = $null
    if ($i -eq 0) {
        # Associate the cluster public IP address with the 1st cluster member
        $addr = $ClusterPublicAddress
    }

    $LoadBalancer = Set-AzureRmLoadBalancer -LoadBalancer $LoadBalancer
    $IpConfig = $LoadBalancer.FrontendIpConfigurations | where -Property Name -EQ $MemberName
    $InboundNatRules = $LoadBalancer.InboundNatRules | where {$_.FrontendIPConfiguration.Id -EQ $IpConfig.Id}
    if ($i -eq 0) {
        $InboundNatRules += $LoadBalancer.InboundNatRules | where {! $_.Name.StartsWith("checkpoint") }
    }

    $nic1 = New-AzureRmNetworkInterface `
        -Name ("ext-" + ($i + 1)) `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -PublicIpAddress $addr `
        -PrivateIpAddress $Subnet1PrivateAddresses[$i] `
        -Subnet $Subnet1 `
        -LoadBalancerInboundNatRule $InboundNatRules `
        -EnableIPForwarding

    $nic2 = New-AzureRmNetworkInterface `
        -Name ("int0-" + ($i + 1)) `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -PrivateIpAddress $Subnet2PrivateAddresses[$i] `
        -Subnet $Subnet2 `
        -EnableIPForwarding

    $nic3 = New-AzureRmNetworkInterface `
        -Name ("int1-" + ($i + 1)) `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -PrivateIpAddress $Subnet3PrivateAddresses[$i] `
        -Subnet $Subnet3 `
        -EnableIPForwarding

    $VMConfig = New-AzureRmVMConfig `
        -VMName $MemberName `
        -VMSize $ClusterVMSize `
        -AvailabilitySetId $AvailabilitySet.Id

    $OSCred = $null
    if ($SSHPAssword) {
        $SecureSSHPassword = ConvertTo-SecureString $SSHPassword -AsPlainText -Force
        $OSCred = New-Object System.Management.Automation.PSCredential ("notused", $SecureSSHPassword)
    }
    Set-AzureRmVMOperatingSystem -VM $VMConfig `
        -Linux `
        -ComputerName $MemberName `
        -Credential $OSCred `
        -CustomData $CustomData

    if ($SSHPublicKey) {
        Add-AzureRmVMSshPublicKey -VM $VMConfig `
            -KeyData $SSHPublicKey `
            -Path "/home/notused/.ssh/authorized_keys"
    }

    Set-AzureRmVMBootDiagnostics -VM $VMConfig `
        -Enable `
        -ResourceGroupName $ResourceGroup `
        -StorageAccountName $StorageAccount

    Set-AzureRmVMSourceImage -VM $VMConfig `
        -PublisherName $Publisher `
        -Offer $Offer `
        -Skus $SKU `
        -Version $Version

    Add-AzureRmVMNetworkInterface -VM $VMConfig `
        -Id $nic1.Id -Primary
    Add-AzureRmVMNetworkInterface -VM $VMConfig `
        -Id $nic2.Id
    Add-AzureRmVMNetworkInterface -VM $VMConfig `
        -Id $nic3.Id

    Set-AzureRmVMOSDisk -VM $VMConfig `
        -Name "osDisk" `
        -VhdUri ("https://" + $StorageAccount + ".blob.core.windows.net/" + $ClusterName + "/osDisk" + ($i + 1) + ".vhd") `
        -Caching ReadWrite `
        -CreateOption FromImage

    $VMConfig.Plan = New-Object Microsoft.Azure.Management.Compute.Models.Plan
    $VMConfig.Plan.Name = $SKU
    $VMConfig.Plan.Publisher = $Publisher
    $VMConfig.Plan.Product = $Offer
    $VMConfig.Plan.PromotionCode = $null

    New-AzureRmVM `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -VM $VMConfig

}

#############################################################################
# Output
#############################################################################

Write-Host "Allocated public IP addresses:"
Write-Host "=============================="
Write-Host "Cluster: " $ClusterPublicAddress.IpAddress
Write-Host "Member1: " $MembersPublicAddresses[0].IpAddress
Write-Host "Member2: " $MembersPublicAddresses[1].IpAddress

