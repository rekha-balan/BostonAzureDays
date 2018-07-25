##############################################
###Azure Days Powershell deployment scripts###
##############################################

Param(
    [Parameter(Mandatory=$True, HelpMessage="Enter your Nike Username in first.last@nike.com format")]
    [string]$ResourceGroupOwner,

    [Parameter(Mandatory=$False, HelpMessage="Enter an optional location in which to add the Resource Group.")]
    [ValidateSet("East US", "West US", "West Europe", "Southeast Asia", "eastus", "westus", "westeurope", "southeastasia")]
    [String]$Location="East US"
)
# Function to log output with timestamp.
function Log-Output($msg) {
    Write-Output "[$(get-date -Format HH:mm:ss)] $msg"
}
# Connect to Azure using AD Credentials
$AzureCredential = Get-AutomationPSCredential -Name 'AzureCredentials'
write-output "retrieved azure credentials $AzureCredential"
Add-AzureRmAccount -Credential $AzureCredential
set-azureRmContext -Subscription az-training-01

$ResourceGroupNameString = (($ResourceGroupOwner.Split('@')[0].Split('.'))[0] + ($ResourceGroupOwner.Split('@')[0].Split('.'))[1])
$OpsResourceGroupName = "azdbos-$ResourceGroupNameString-ops-rg-01"
$VnetResourceGroupName = "azdbos-$ResourceGroupNameString-vnet-rg-01"
$VmResourceGroupName = "azdbos-$ResourceGroupNameString-vm-rg-01"
$ResourceGroupNameArray = ($OpsResourceGroupName,$VnetResourceGroupName,$VmResourceGroupName)

# Build Tags Parameters
$Tags = @{
    Owner       = $ResourceGroupOwner
    CostCenter  = "999999"
    Environment = "Training"
}


# Check if Resource Group already exists / Create if not
$AzureAdUser = Get-AzureRMADUser -UserPrincipalName $ResourceGroupOwner
foreach ($ResourceGroupName in $ResourceGroupNameArray)
    {
        try{
            $AlreadyExists = Get-AzureRmResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose -Message 'Resource Group could not be found'
        }
        if ($AlreadyExists) {
            Write-Warning "ResourceGroup with name $ResourceGroupName already exists."
        } else {
            # Create resource group
            try {
                $null = New-AzureRmResourceGroup -Name $ResourceGroupName `
                                                 -Location $Location `
                                                 -Tag $Tags `
                                                 -ErrorAction Stop
            } catch { 
    	        throw "$($_.exception.message)" 
            }
            try {
                $Role = New-AzureRmRoleAssignment `
                    -ResourceGroupName $ResourceGroupName `
                    -RoleDefinitionName "Contributor" `
                    -SignInName $ResourceGroupOwner `
                    -ErrorAction Stop
            } catch { 
    	        throw "$($_.exception.message)" 
            }
            try {
                $Role = New-AzureRmRoleAssignment `
                    -Scope "/subscriptions/b01276dd-92b7-43d1-bf61-c03f0788a8d8" `
                    -RoleDefinitionName "Reader" `
                    -SignInName $ResourceGroupOwner `
                    -ErrorAction Stop
            } catch { 
    	        throw "$($_.exception.message)" 
            }
        }
    }
#initial steps --if you have access to multiple subscriptions uncomment below & add correct sub name
$artifactsLocation = "https://raw.githubusercontent.com/mmcsa/BostonAzureDays/master"
$omsRecoveryVaultName = "azdbos-$ResourceGroupNameString-rv-01"
$omsWorkspaceName        = "azdbos-$ResourceGroupNameString-law-01"
$omsAutomationAccountName= "azdbos-$ResourceGroupNameString-aa-01"
$azureAdminVar = Get-AzureRmAutomationVariable -ResourceGroupName "azd-sharedops-rg-01" -AutomationAccountName "azd-sharedops-aa-01" -Name "vmAdminPwd"
$azureAdminPwd = "$azureAdminVar"

# set resource group names from username

#######################################################
###deploy OMS and Automation accounts from templates###
#######################################################
$omsTemplatePath = "$artifactsLocation/OMS/omsMaster-deploy.json"
$omsParameters = @{
    omsRecoveryVaultName    = $omsRecoveryVaultName
    omsRecoveryVaultRegion  = "East US"
    omsWorkspaceName        = $omsWorkspaceName
    omsWorkspaceRegion      = "East US"
    omsAutomationAccountName= $omsAutomationAccountName
    omsAutomationRegion     = "East US 2"
    azureAdmin              = $ResourceGroupOwner
    azureAdminPwd           = $azureAdminPwd
}
New-AzureRmResourceGroupDeployment `
    -Name azdOmsDeploy `
    -ResourceGroupName $opsResourceGroupName `
    -TemplateFile $omsTemplatePath `
    -TemplateParameterObject $omsParameters `
    -Mode Incremental `
    -Verbose

#####################################
###Deploy KeyVault and add secrets###
#####################################
$keyvaultName = "azdbos-$ResourceGroupNameString-kv-01"
New-AzureRmKeyVault `
    -VaultName $keyvaultName `
    -ResourceGroupName $opsResourceGroupName `
    -Location $location `
    -EnabledForTemplateDeployment

#Get resource ID of KeyVault for VM template parameters
$Vault = Get-AzureRmKeyVault -VaultName $keyvaultName -ResourceGroupName $OpsResourceGroupName
Set-AzureRmKeyVaultAccessPolicy -InputObject $Vault -UserPrincipalName $ResourceGroupOwner -PermissionsToSecrets get,list,set -PermissionsToKeys get,list -PermissionsToStorage get,list,set -PermissionsToCertificates get,list
$vaultId = $vault.ResourceId
#get OMS workspace name & keys, store key in vault.
$omsWorkspace = Get-AzureRmOperationalInsightsWorkspace -ResourceGroupName $opsResourceGroupName
$omsKeys = Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $opsResourceGroupName -Name $omsWorkspace.Name
$omsPrimaryKey = $omsKeys.PrimarySharedKey
$omsSecret = ConvertTo-SecureString $omsPrimaryKey -AsPlainText -force
$omsVault = Set-AzureKeyVaultSecret -VaultName $keyvaultName -Name 'omsKey' -SecretValue $omsSecret

#store Admin password in Keyvault
$adminUserName = $ResourceGroupNameString
$adminUserNameVar = New-AzureRmAutomationVariable -Encrypted $false -Name "adminuser" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $adminUserName
$azureAdminPwdSecure = ConvertTo-SecureString -String $azureAdminPwd -AsPlainText -Force
$secret = Set-AzureKeyVaultSecret -VaultName $keyvaultName -Name 'vmAdminPassword' -SecretValue $azureAdminPwdSecure

###########################################################################
#get Automation registration info for DSC, set variables for VM deployment#
#we will be placing deployment variables & credentials in Automation      #
###########################################################################
$RegistrationInfo = Get-AzureRmAutomationRegistrationInfo -ResourceGroupName $OpsResourceGroupName -AutomationAccountName $omsAutomationAccountName
$registrationUrl = $RegistrationInfo.Endpoint
$registrationKey = $RegistrationInfo.PrimaryKey
$storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $opsResourceGroupName 
$storageAccountKeys = Get-AzureRmStorageAccountKey -ResourceGroupName $opsResourceGroupName -Name $storageAccount.StorageAccountName
$storagePrimaryKey = $storageAccountKeys[0].value
$opsRgVar = New-AzureRmAutomationVariable -Encrypted $false -Name "opsResourceGroupName" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $opsResourceGroupName
$vnetRgVar = New-AzureRmAutomationVariable -Encrypted $false -Name "VnetResourceGroup" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $vnetresourceGroupName
$vmRgVar = New-AzureRmAutomationVariable -Encrypted $false -Name "VmResourceGroup" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $VmResourceGroupName
$artifactsVar = New-AzureRmAutomationVariable -Encrypted $false -Name "artifactsLocation" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $artifactsLocation
$storageAccountNameVar = New-AzureRmAutomationVariable -Encrypted $false -Name "saname" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $storageAccount.StorageAccountName
$storageAccountKeyVar = New-AzureRmAutomationVariable -Encrypted $true -Name "sakey" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $storagePrimaryKey
$KeyVaultIdVar = New-AzureRmAutomationVariable -Encrypted $true -Name "vaultid" -ResourceGroupName $opsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $vaultId
$AzureCredentialCred = New-AzureRmAutomationCredential -Name "AzureCredential" -ResourceGroupName $OpsResourceGroupName -AutomationAccountName $omsAutomationAccountName -Value $AzureCredential


##########################################
#copy website content from GIT to storage#
##########################################
$Context = New-AzureStorageContext -StorageAccountName $storageAccount.StorageAccountName -StorageAccountKey $storagePrimaryKey
$container = New-AzureStorageContainer -Name "website-bits" -Context $Context
Start-AzureStorageBlobCopy -AbsoluteUri "$artifactsLocation/website.zip" -DestContainer $container.Name -DestBlob "azdays-website.zip" -DestContext $Context

#####################
###VNet deployment###
#####################

#Deploy VNET from template

$vnetTemplatePath = "$artifactsLocation/simplevnet.json"
$vnetName = "azdbos-$ResourceGroupNameString-vnet-01"
$vnetAddressPrefix = "10.2.0.0/16"
$subnet1Prefix = "10.2.1.0/24"
$subnet1Name = "subnet1"
$subnet2Prefix = "10.2.2.0/24"
$subnet2Name = "subnet2"
$subnet3Prefix = "10.2.3.0/24"
$subnet3Name = "subnet3"
$vnetParams =@{
    "vnetName"          = $vnetName
    "vnetAddressPrefix" = $vnetAddressPrefix
    "subnet1Prefix"     = $subnet1Prefix
    "subnet1Name"       = $subnet1Name
    "subnet2Prefix"     = $subnet2Prefix
    "subnet2Name"       = $subnet2Name
    "subnet3Prefix"     = $subnet3Prefix
    "subnet3Name"       = $subnet3Name
}
New-AzureRmResourceGroupDeployment `
    -Name azdVnetDeploy `
    -ResourceGroupName $vnetresourceGroupName `
    -TemplateFile $vnetTemplatePath `
    -TemplateParameterObject $vnetParams `
    -Mode Incremental `
    -Verbose


##############################
###Load Balancer Deployment###
##############################

#create Public IP for LB
$publicIP = New-AzureRmPublicIpAddress `
  -ResourceGroupName $VNetresourceGroupName `
  -Location $location `
  -AllocationMethod Dynamic `
  -Name "azdbos-$ResourceGroupNameString-pip-01"

#front-end IP for LB
$frontendIP = New-AzureRmLoadBalancerFrontendIpConfig `
  -Name myFrontEndPool `
  -PublicIpAddress $publicIP

#backend pool
$backendPool = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name myBackEndPool

#create Load Balancer
$lb = New-AzureRmLoadBalancer `
  -ResourceGroupName $VNetresourceGroupName `
  -Name azd-lb-01 `
  -Location $location `
  -FrontendIpConfiguration $frontendIP `
  -BackendAddressPool $backendPool

#create port 80 probe
Add-AzureRmLoadBalancerProbeConfig `
  -Name HttpProbe `
  -LoadBalancer $lb `
  -Protocol tcp `
  -Port 80 `
  -IntervalInSeconds 15 `
  -ProbeCount 2
Set-AzureRmLoadBalancer -LoadBalancer $lb
$probe = Get-AzureRmLoadBalancerProbeConfig -LoadBalancer $lb -Name HttpProbe

#add LB rule for port 80
Add-AzureRmLoadBalancerRuleConfig `
  -Name HttpRule `
  -LoadBalancer $lb `
  -FrontendIpConfiguration $lb.FrontendIpConfigurations[0] `
  -BackendAddressPool $lb.BackendAddressPools[0] `
  -Protocol Tcp `
  -FrontendPort 80 `
  -BackendPort 80 `
  -Probe $probe

Set-AzureRmLoadBalancer -LoadBalancer $lb

#configure RDP NAT Rules
$lb | Add-AzureRmLoadBalancerInboundNatRuleConfig `
    -Name RDP1 `
    -FrontendIpConfiguration $lb.FrontendIpConfigurations[0] `
    -Protocol TCP `
    -FrontendPort 3441 `
    -BackendPort 3389

$lb | Add-AzureRmLoadBalancerInboundNatRuleConfig `
-Name RDP2 `
-FrontendIpConfiguration $lb.FrontendIpConfigurations[0] `
-Protocol TCP `
-FrontendPort 3442 `
-BackendPort 3389

Set-AzureRmLoadBalancer -LoadBalancer $lb

<# #############################################################
#create Azure Container Registry                            #
#we will be pushing a docker image from VMs after deployment#
#############################################################
$registry = New-AzureRmContainerRegistry -Name "azdmatmorganacr01" -ResourceGroupName $opsResourceGroupName -Sku Basic -EnableAdminUser
$dockerCredential = Get-AzureRmContainerRegistryCredential -ResourceGroupName $opsResourceGroupName -Name $registry.Name 
$dockerCredential

$dockerSecurePass = ($dockerCredential.Password | ConvertTo-SecureString -AsPlainText -Force)
$dockerCredential = New-Object System.Management.Automation.PSCredential ($dockerCredential.Username, $dockerSecurePass)

#copy LoginServer for use in docker image tag.
#copy username & password for docker login

#check DSC Compliance
Get-AzureRmAutomationDscNode -AutomationAccountName $omsAutomationAccountName -ResourceGroupName $opsResourceGroupName

#####################################
#deploy docker image to ACI instance#
####################################

$aci = New-AzureRmContainerGroup `
    -ResourceGroupName $vmResourceGroup `
    -Name azd-matmorgan-site `
    -Image azdmatmorganacr01.azurecr.io/iis-site:v1 `
    -OsType Windows `
    -IpAddressType Public `
    -Port 8000 `
    -RegistryCredential $dockerCredential

 #>