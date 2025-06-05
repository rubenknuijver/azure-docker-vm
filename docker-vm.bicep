@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of the Virtual Machine.')
param vmName string = 'docker-vm'

@description('Size of the Virtual Machine.')
param vmSize string = 'Standard_DS2_v2' // Or Standard_B2s for cost savings

@description('Admin username for the Virtual Machine.')
param adminUsername string = 'azureuser'

@description('Password for the admin user. Required if not using SSH key.')
@secure()
param adminPassword string = ''

@description('SSH public key for the admin user. If provided, password will be ignored for VM login.')
param adminSshPublicKey string = ''

@description('Your local public IP address to allow SSH access. Example: "203.0.113.45". Use "DETECT" to auto-detect in PowerShell script.')
param sourceMyIpAddress string

@description('Virtual network name.')
param vnetName string = 'docker-vnet'

@description('Subnet name.')
param subnetName string = 'docker-subnet'

@description('Public IP address name.')
param publicIpName string = '${vmName}-pip'

@description('Network security group name.')
param nsgName string = '${vmName}-nsg'

@description('Network interface name.')
param nicName string = '${vmName}-nic'

var imageReference = {
  publisher: 'Canonical'
  offer: '0001-com-ubuntu-server-jammy' // Ubuntu Server 22.04 LTS
  sku: '22_04-lts-gen2'
  version: 'latest'
}
var vnetAddressPrefix = '10.0.0.0/16'
var subnetAddressPrefix = '10.0.0.0/24'

// --- Network Security Group ---
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'SSH_From_MyIP'
        properties: {
          description: 'Allow SSH from my public IP'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: sourceMyIpAddress
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'DOCKER_From_MyIP'
        properties: {
          description: 'Allow Docker from my public IP'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '2375'
          sourceAddressPrefix: sourceMyIpAddress
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 101
          direction: 'Inbound'
        }
      }
    ]
  }
}

// --- Public IP Address ---
resource publicIp 'Microsoft.Network/publicIpAddresses@2023-05-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard' // Standard SKU is recommended for production
  }
  properties: {
    publicIPAllocationMethod: 'Static' // Static IP is good for a server
    dnsSettings: {
      domainNameLabel: toLower('${vmName}-${uniqueString(resourceGroup().id)}')
    }
  }
}

// --- Virtual Network ---
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
    ]
  }
}

// --- Network Interface ---
resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// --- Virtual Machine ---
resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: (empty(adminSshPublicKey) ? adminPassword : null) // Use password only if SSH key is not provided
      linuxConfiguration: (!empty(adminSshPublicKey) ? {
        disablePasswordAuthentication: true // More secure if using SSH keys
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      } : null)
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS' // Or Premium_LRS for better performance
        }
        deleteOption: 'Delete' // Delete OS disk when VM is deleted
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// --- Custom Script Extension to install Docker ---
resource vmDockerExtension 'Microsoft.Compute/virtualMachines/extensions@2023-07-01' = {
  parent: vm
  name: 'InstallDocker'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      // Using a "here-string" like approach for the script
      // The script ensures Docker is installed and the user is added to the docker group.
      // It also ensures SSHD is configured to allow key auth and (if no key specified for VM) password auth.
      // PasswordAuthentication yes in sshd_config is important if you plan to use password for the Docker context SSH connection.
      // If you only use SSH keys for Docker context, you can set it to 'no' for better security IF the VM itself is also key-only.
      script: base64(format(
        '''#!/bin/bash
        sudo apt-get update -y
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

        # Add Docker's official GPG key
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        # Add Docker repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Add admin user to docker group
        sudo usermod -aG docker {0}

        # Configure SSHD for Docker context (especially if using password for context)
        # If VM is key-only, PubkeyAuthentication is already yes.
        # PasswordAuthentication is needed if Docker context will use password.
        if ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config && [ -z "{1}" ]; then
            sudo sed -i 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
            sudo systemctl restart sshd
        elif [ -n "{1}" ]; then
            # If SSH key is used for VM, ensure PubkeyAuthentication is explicitly yes
            # and consider setting PasswordAuthentication no for better security.
            # However, for Docker context, PasswordAuthentication might still be desired by some users.
            # For now, we'll ensure Pubkey is on and leave PasswordAuthentication as is or as set above.
             sudo sed -i 's/^#?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
             # Optional: if VM is key-only AND docker context will also be key-only:
             # sudo sed -i 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
             sudo systemctl restart sshd
        fi

        echo "Docker installation and configuration complete."
        # A reboot might be needed for group changes to take full effect for interactive shells,
        # but for Docker context via SSH, it should work.
        ''', adminUsername, adminSshPublicKey
      ))
    }
    // protectedSettings can be used if the script contains secrets
  }
}

// --- Outputs ---
output vmName string = vm.name
output adminUsername string = adminUsername
output publicIpAddress string = publicIp.properties.ipAddress
output fqdn string = publicIp.properties.dnsSettings.fqdn
output sshCommand string = (!empty(adminSshPublicKey) ? format('ssh {0}@{1}', adminUsername, publicIp.properties.dnsSettings.fqdn) : format('ssh {0}@{1} (Use password: {2})', adminUsername, publicIp.properties.dnsSettings.fqdn, adminPassword))
