﻿#create multiple VMs from ARM Template with provided parameters. 
#DSC and OMS extensions configured with DSC node config as selected. 
Param
(
    # name of Resource Group with Automation account deployed
    [Parameter(Mandatory=$true, HelpMessage="Name of Resource Group for automation acccount")]
    [string]$opsResourceGroup,
    
    # prefix for VM names
    [Parameter(Mandatory=$true, HelpMessage="prefix for VM names")]
    [string]$vmNamePrefix,

    #VM Size
    [Parameter(Mandatory=$false, HelpMessage="Enter the Vm Size.")]
    [ValidateSet("Standard_D2_v3")]
    [String]$VmSize="Standard_D2_v3",

    # number of VMs to deploy
    [Parameter(Mandatory=$false, HelpMessage="number of identical VMs to deploy")]
    [int]$numberOfInstances=2,

    # DSC Node config to use
    [Parameter(Mandatory=$false, HelpMessage="DSC configuration to apply")]
    [ValidateSet("Web")]
    [string]$nodeConfigurationName="Web"
)
# Function to log output with timestamp.
#initial steps --if you have access to multiple subscriptions uncomment below & add correct sub name
function Log-Output($msg) {
    Write-Output "[$(get-date -Format HH:mm:ss)] $msg"
}
# Connect to Azure using AD Credentials
#$AzureCredential = Get-AutomationPSCredential -Name 'AzureCredential'
#Log-Output "retrieved azure credentials $AzureCredential"
#Add-AzureRmAccount -Credential $AzureCredential
set-azureRmContext -Subscription az-training-01
$keyvault = Get-AzureRmKeyVault -ResourceGroupName $OpsResourceGroup

Log-Output ("connected to subscription " + $armContext.Subscription +" as " + $armContext.Account.Id)
Log-Output "secrets being retrieved from keyvault = " + $keyvault.VaultName

#get Automation info for DSC & retrieve variables and keys
$adminSecret = Get-AzureKeyVaultSecret -VaultName $keyvault.VaultName -Name 'vmAdminPassword'
$adminPassword = ($adminSecret.SecretValueText | ConvertTo-SecureString -AsPlainText -Force)
$Account = Get-AzureRmAutomationAccount -ResourceGroupName $OpsResourceGroup
$autoAccountName = $account.AutomationAccountName
$adminUserVar = (Get-AzureRmAutomationVariable -ResourceGroupName $opsResourceGroup -AutomationAccountName $autoAccountName -Name "adminuser").Value
$adminUsername = "$adminUserVar"
$vnetResourceVar = (Get-AzureRmAutomationVariable -ResourceGroupName $opsResourceGroup -AutomationAccountName $autoAccountName -Name "VnetResourceGroup").Value
$vnetResourceGroup = "$vnetResourceVar" ##for whatever reason some retreived vars can't be directly passed unless redeclared as strings
$vmResourceVar = (Get-AzureRmAutomationVariable -ResourceGroupName $opsResourceGroup -AutomationAccountName $autoAccountName -Name "VmResourceGroup").Value
$vmResourceGroup = "$vmResourceVar" ##for whatever reason some retreived vars can't be directly passed unless redeclared as strings 
$artifactsLocation = (Get-AzureRmAutomationVariable -ResourceGroupName $opsResourceGroup -AutomationAccountName $autoAccountName -Name "ArtifactsLocation").Value
$vaultId = (Get-AzureRmAutomationVariable -ResourceGroupName $opsResourceGroup -AutomationAccountName $autoAccountName -Name "vaultid").Value

#get VNET info and set subnet based on config selected
$vnet = Get-AzureRmVirtualNetwork -ResourceGroupName $vnetresourceGroup
$vnetName = $vnet.Name
$subnets = $vnet.Subnets
$vmSubnetName = $subnets[1].Name

Log-Output ("VMs will be placed in VNET = " + $vnetName + ", subnet = " + $vmSubnetName)

#get OMS workspace info
$omsWorkspace = Get-AzureRmOperationalInsightsWorkspace -ResourceGroupName $OpsResourceGroup
$workspaceId = $omsWorkspace.CustomerId.Guid
$workspaceSecret = Get-AzureKeyVaultSecret -VaultName $keyvault.VaultName -Name 'omsKey'
$workspaceKey = ($workspaceSecret.SecretValueText | ConvertTo-SecureString -AsPlainText -Force)
$nodeConfiguration = "WebConfig.$nodeConfigurationName"

$availabilitySetName = "azdbos-$adminUsername-as-01"


Log-Output ("automation account $autoAccountName found")
Log-Output ("DSC registration URL $registrationUrl will be used")
Log-Output ("OMS workspace " + $omsWorkspace.Name + " will be used for Log Analytics")

$vmTemplateUri = "$artifactsLocation/Windows-2016-VM-Template.json"

Log-Output "Setting template parameters."
$params =[ordered]@{
    adminUsername               = $adminUsername;
    availabilitySetName         = $availabilitySetName;
    vmNamePrefix                = $vmNamePrefix;
    vmSize                      = $VmSize;
    numberOfInstances           = $numberOfInstances;
    virtualNetworkName          = $vnetName;
    virtualNetworkResourceGroup = $vnetResourceGroup;
    subnetName                  = $vmSubnetName;
    nodeConfigurationName       = $nodeConfiguration

}

# Pull automation account info
$RegistrationInfo = Get-AzureRmAutomationRegistrationInfo -ResourceGroupName $OpsResourceGroup -AutomationAccountName $AutoAccountName

# Add parameter variables for DSC registration with key
$registrationKey = ($RegistrationInfo.PrimaryKey | ConvertTo-SecureString -AsPlainText -Force)
$RegistrationUrl = $RegistrationInfo.Endpoint
# same for OMS workspace Key
$workspaceKey = ($workspaceSecret.SecretValueText | ConvertTo-SecureString -AsPlainText -Force)

# Add secure strings to parameters hash file separately. 
$params.Add("adminPassword", $adminPassword)
$params.Add("registrationKey", $registrationKey)
$params.Add("RegistrationUrl", $RegistrationUrl)
$params.Add("workspaceID", $workspaceId)
$params.Add("workspaceKey", $workspaceKey)

##Deploy the Vms 
Log-Output "Starting deployment."
try {
    $Deployment = New-AzureRmResourceGroupDeployment `
        -Name                        "NikeAzDayDeploy-$(([guid]::NewGuid()).Guid)" `
        -ResourceGroupName           $vmResourceGroup `
        -TemplateUri                 $vmTemplateUri `
        -TemplateParameterObject     $params `
        -Mode                        incremental `
        -Force `
        -Verbose
} catch { throw $_ }

##attach the NSG to the VM subnet
$subnetConfig = Set-AzureRmVirtualNetworkSubnetConfig `
    -Name $vmSubnetName `
    -AddressPrefix $subnets[1].AddressPrefix `
    -VirtualNetwork $vnet `
    -NetworkSecurityGroup $nsg 

Log-Output "attaching NSG to subnet $vmSubnetName"

$vnet = Set-AzureRmVirtualNetwork -VirtualNetwork $vnet

Log-Output "******deployment complete******"

#########################################################################
#add VMs to Load Balancer with RDP NAT rules mapped across multiple VMs.# 
#########################################################################
$vms = Get-AzureRmVM -ResourceGroupName $vmResourceGroup
$lb = Get-AzureRmLoadBalancer -Name azd-lb-01 -ResourceGroupName $vnetresourceGroup
$vmCount = 0
foreach ($vm in $vms)
    {     
        $nicId = $vm.NetworkProfile.NetworkInterfaces.id
        $nicName = $nicId.split('/')[8]
        $nic = get-azureRMNetworkInterface -Name $nicName -ResourceGroupName $vmResourceGroup
        $nic.IpConfigurations[0].LoadBalancerBackendAddressPools=$lb.BackendAddressPools[$vmCount]
        $nic.IpConfigurations[0].LoadBalancerInboundNatRules=$lb.InboundNatRules[$vmCount]
        Set-AzureRmNetworkInterface -NetworkInterface $nic
        $vmCount++
    }


    