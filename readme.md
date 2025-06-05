# Docker VM - Remote Context

## How to Use

1.  **Install Tools:**
    *   **Azure CLI:** Though the script uses Azure PowerShell, having Azure CLI can be useful for other operations. `az login`.
    *   **Azure PowerShell:** Install from PowerShell Gallery: `Install-Module Az -Scope CurrentUser -Repository PSGallery -Force`. Then `Connect-AzAccount`.
    *   **Docker Desktop (or Docker CLI):** You need the `docker` command locally to create and use contexts.
    *   **SSH Client:** Windows 10/11 has a built-in OpenSSH client. Git Bash also includes one.
    *   **`ssh-keygen`:** Usually comes with SSH client or Git installation.

2.  **Save Files:** Save `docker-vm.bicep` and `deploy-docker-vm.ps1` in the same directory.

3.  **Configure PowerShell Script:**
    *   Open `deploy-docker-vm.ps1` in an editor.
    *   Set `$subscriptionId` if necessary.
    *   Adjust `$resourceGroupName`, `$location`, `$vmName`, `$adminUsername`.
    *   Decide on `$useSshKeyAuthentication`. If `false`, be ready to input `$adminPassword` or set it in the script (less secure for hardcoding).
    *   Review `$myPublicIp`. If "DETECT" doesn't work for you (e.g., you're behind a proxy or complex NAT), manually set your public IP address. You can find it by searching "what is my IP" in Google.

4.  **Run PowerShell Script:**
    *   Open PowerShell.
    *   Navigate to the directory where you saved the files.
    *   Execute: `.\deploy-docker-vm.ps1`
    *   The script will guide you, deploy the resources, and then output the commands to set up your Docker context.

5.  **Set Up Docker Context Locally:**
    *   After the PowerShell script completes successfully, it will print commands like:
        ```
        # If using SSH key:
        docker context create azure-myazuredocker --docker "host=ssh://azureuser@your-vm-fqdn.westeurope.cloudapp.azure.com" --ssh "identity=C:/Users/YourUser/.ssh/azure_docker_vm_id_rsa"

        # If using password:
        docker context create azure-myazuredocker --docker "host=ssh://azureuser@your-vm-fqdn.westeurope.cloudapp.azure.com"
        ```
    *   Copy and run the appropriate `docker context create` command in your local terminal (PowerShell, CMD, Git Bash, etc.).
    *   Then run:
        ```
        docker context use azure-myazuredocker
        docker context ls  # To verify, the new context should have a '*'
        docker ps          # This command will now run on your Azure VM!
        docker run hello-world # This will pull and run on the Azure VM
        ```

6.  **Switching Back:** To switch back to your local Docker daemon (if you have one, e.g., from Docker Desktop):
    `docker context use default`