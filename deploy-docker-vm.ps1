#Requires -Modules Az.Accounts, Az.Resources, Az.Network

# --- Configuration ---
$subscriptionId = "" # Optional: Specify if you have multiple subscriptions. Otherwise, current context is used.
$resourceGroupName = "rg-docker-dev-weu-1" # Name of the Resource Group to create or use
$location = "WestEurope" # Choose an Azure region
$vmName = "vm-azuredocker-dev-1" # Name of the VM to create
$adminUsername = "azureuser"

# --- SSH Key Configuration ---
# Set to $true to use SSH key authentication (recommended)
# Set to $false to use password authentication (provide $adminPassword below)
$useSshKeyAuthentication = $true
$sshKeyName = "azure_docker_vm_id_rsa" # Name of the SSH key file (without .pub)
$sshKeyPath = "$HOME\.ssh\$sshKeyName" # Path to store/find SSH keys

# --- Password Configuration (only if $useSshKeyAuthentication is $false) ---
$adminPassword = $null # Set a strong password here if not using SSH keys. Will be prompted if empty.

# --- Your Public IP for NSG ---
# Set to "DETECT" to attempt auto-detection.
# Otherwise, set your static public IP, e.g., "203.0.113.45"
# If behind a CGNAT or dynamic IP, this might need frequent updates or a broader range (less secure).
$myPublicIp = "DETECT"

# --- Script ---

# Login to Azure (if not already logged in)
Try {
    Write-Host "Checking Azure login status..."
    Get-AzContext -ErrorAction Stop | Out-Null
    Write-Host "Already logged in to Azure."
}
Catch {
    Write-Host "Not logged in. Please login to Azure."
    Connect-AzAccount
}

if (-not [string]::IsNullOrEmpty($subscriptionId)) {
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    Write-Host "Switched to subscription: $subscriptionId"
} else {
    $subscriptionId = (Get-AzContext).Subscription.Id
    Write-Host "Using current subscription: $subscriptionId"
}


# Auto-detect public IP if configured
if ($myPublicIp -eq "DETECT") {
    try {
        Write-Host "Attempting to detect your public IP address..."
        $detectedIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
        if ($detectedIp -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
            $myPublicIp = $detectedIp
            Write-Host "Successfully detected your public IP: $myPublicIp"
        } else {
            Write-Warning "Could not reliably detect public IP. Please enter it manually."
            $myPublicIp = Read-Host "Enter your public IP address (e.g., 203.0.113.45)"
        }
    }
    catch {
        Write-Warning "Failed to auto-detect public IP: $($_.Exception.Message)"
        $myPublicIp = Read-Host "Enter your public IP address (e.g., 203.0.113.45)"
    }
} elseif (-not ($myPublicIp -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$" -or $myPublicIp -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$")) {
    Write-Warning "Invalid IP format for '$myPublicIp'."
    $myPublicIp = Read-Host "Enter your public IP address (e.g., 203.0.113.45 or 203.0.113.0/24)"
}


# SSH Key Handling
$sshPublicKeyContent = ""
if ($useSshKeyAuthentication) {
    $publicKeyFile = "$sshKeyPath.pub"
    $privateKeyFile = $sshKeyPath

    if (-not (Test-Path $publicKeyFile) -or -not (Test-Path $privateKeyFile)) {
        Write-Host "SSH key pair not found at $sshKeyPath. Generating new one..."
        # Ensure .ssh directory exists
        $sshDir = Split-Path -Path $privateKeyFile
        if (-not (Test-Path $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        }
        # Generate SSH key pair without passphrase for simplicity in this script
        # For higher security, consider adding a passphrase and using ssh-agent
        ssh-keygen -t rsa -b 4096 -f $privateKeyFile -q -N "" # -N "" for no passphrase
        Write-Host "Generated SSH key pair: $privateKeyFile and $publicKeyFile"
    } else {
        Write-Host "Using existing SSH key: $publicKeyFile"
    }
    $sshPublicKeyContent = Get-Content -Path $publicKeyFile -Raw
} else {
    if ([string]::IsNullOrWhiteSpace($adminPassword)) {
        $adminPassword = Read-Host -Prompt "Enter a strong password for the VM admin user '$adminUsername'" -AsSecureString
    }
}

# Create Resource Group if it doesn't exist
Write-Host "Checking for Resource Group: $resourceGroupName"
Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue | Out-Null
if (!$?) {
    Write-Host "Creating Resource Group: $resourceGroupName in $location"
    New-AzResourceGroup -Name $resourceGroupName -Location $location -Force | Out-Null
} else {
    Write-Host "Resource Group $resourceGroupName already exists."
}

# Prepare Bicep parameters
$bicepParameters = @{
    location = $location
    vmName = $vmName
    adminUsername = $adminUsername
    sourceMyIpAddress = $myPublicIp
    # Add other parameters from bicep file as needed
}

if ($useSshKeyAuthentication) {
    $bicepParameters.adminSshPublicKey = $sshPublicKeyContent
    # The Bicep template will set adminPassword to null if adminSshPublicKey is provided
} else {
    # For password auth, ensure adminSshPublicKey is empty or not passed
    # $bicepParameters.adminPassword = $adminPassword # Not needed directly, Bicep expects SecureString
}

# Deploy Bicep template
Write-Host "Starting Bicep deployment for $vmName in $resourceGroupName..."
$deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroupName `
    -TemplateFile ".\docker-vm.bicep" `
    -TemplateParameterObject $bicepParameters `
    -adminPassword:$adminPassword # Pass SecureString directly for parameters of @secure() type

if ($deployment.ProvisioningState -eq "Succeeded") {
    Write-Host "Bicep deployment successful!" -ForegroundColor Green
    $vmPublicIp = $deployment.Outputs.publicIpAddress.Value
    $vmFqdn = $deployment.Outputs.fqdn.Value
    $vmUser = $deployment.Outputs.adminUsername.Value

    Write-Host ""
    Write-Host "---------------- Azure Docker VM Details ----------------" -ForegroundColor Cyan
    Write-Host "VM Name:          $vmName"
    Write-Host "Admin Username:   $vmUser"
    Write-Host "Public IP:        $vmPublicIp"
    Write-Host "FQDN:             $vmFqdn"

    if ($useSshKeyAuthentication) {
        Write-Host "SSH Key:          $privateKeyFile (Private), $publicKeyFile (Public)"
        Write-Host "SSH Command:      ssh -i ""$privateKeyFile"" $vmUser@$vmFqdn"
    } else {
        Write-Host "SSH Command:      ssh $vmUser@$vmFqdn (Use the password you provided)"
    }
    Write-Host "---------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "To set up your local Docker context:" -ForegroundColor Yellow
    $dockerContextName = "azure-$vmName"
    $sshConnectionString = "ssh://$vmUser@$vmFqdn"

    Write-Host "1. Create the Docker context:"
    if ($useSshKeyAuthentication) {
        # Docker context create uses forward slashes for paths, even on Windows
        $dockerSshKeyPath = $privateKeyFile.Replace("\", "/")
        Write-Host "   docker context create $dockerContextName --docker ""host=$sshConnectionString"" --ssh ""identity=$dockerSshKeyPath""" -ForegroundColor Green
    } else {
        Write-Host "   docker context create $dockerContextName --docker ""host=$sshConnectionString""" -ForegroundColor Green
        Write-Host "   (You will be prompted for the VM password when using this context)"
    }

    Write-Host "2. Switch to the new context:"
    Write-Host "   docker context use $dockerContextName" -ForegroundColor Green
    Write-Host "3. Verify the context:"
    Write-Host "   docker context ls" -ForegroundColor Green
    Write-Host "   docker ps  (or docker --context $dockerContextName ps)" -ForegroundColor Green
    Write-Host ""
    Write-Host "If you just created the SSH key and get a 'permissions are too open' error for the private key on Linux/macOS for the SSH command,"
    Write-Host "run: chmod 600 ""$privateKeyFile"""
    Write-Host ""
    Write-Host "NOTE: If group membership changes for '$vmUser' (added to 'docker' group) don't take effect immediately for the SSH session"
    Write-Host "      used by the Docker context, you might need to reboot the VM or the SSH session might re-evaluate on next connect."
    Write-Host "      The custom script tries to handle this, but a VM reboot ('az vm restart -g $resourceGroupName -n $vmName') can be a quick fix if needed."

} else {
    Write-Error "Bicep deployment failed. ProvisioningState: $($deployment.ProvisioningState)"
    if ($deployment.Error) {
        Write-Error "Error Details: $($deployment.Error.Message)"
        if ($deployment.Error.Details) {
            $deployment.Error.Details | ForEach-Object { Write-Error "  $($_.Message)" }
        }
    }
}