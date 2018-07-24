##Azure Days Training
##Resource Group creation runbook

Param(
    [Parameter(Mandatory=$True, HelpMessage="Enter your Nike Username in first.last@nike.com format")]
    [string]$ResourceGroupOwner,

    [Parameter(Mandatory=$False, HelpMessage="Enter an optional location in which to add the Resource Group.")]
    [ValidateSet("East US", "West US", "West Europe", "Southeast Asia", "eastus", "westus", "westeurope", "southeastasia")]
    [String]$Location="West Europe"
)

# Connect to Azure using AD Credentials
$AzureCredential = Get-AutomationPSCredential -Name 'AzureCredentials'
$null = Connect-AzureRmAccount -Credential $AzureCredential -Subscription b01276dd-92b7-43d1-bf61-c03f0788a8d8
set-azureRmContext -Subscription az-training-01

$ResourceGroupNameString = (($ResourceGroupOwner.Split('@')[0].Split('.'))[0] + ($ResourceGroupOwner.Split('@')[0].Split('.'))[1])
$OpsResourceGroupName = "azd-$ResourceGroupNameString-ops-rg-01"
$VnetResourceGroupName = "azd-$ResourceGroupNameString-vnet-rg-01"
$VmResourceGroupName = "azd-$ResourceGroupNameString-vm-rg-01"
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
        }
    }

