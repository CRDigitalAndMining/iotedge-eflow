<#
    .DESCRIPTION
        This module contains the functions related to EFLOW setup on a PC
#>
param(
    [switch] $AutoDeploy
)

New-Variable -Name eflowAutoDeployVersion -Value "1.0.220831.0800" -Option Constant -ErrorAction SilentlyContinue
#Hashtable to store session information
$eadSession = @{
    "HostPC"         = @{"FreeMem" = 0; "TotalMem" = 0; "FreeDisk" = 0; "TotalDisk" = 0; "TotalCPU" = 0; "Name" = $null }
    "HostOS"         = @{"Name" = $null; "Version" = $null; "IsServerSKU" = $false; "IsVM" = $false; "IsAzureVM" = $false }
    "EFLOW"          = @{"Product" = $null; "Version" = $null }
    "UserConfig"     = $null
    "UserConfigFile" = $null
}

New-Variable -Option Constant -ErrorAction SilentlyContinue -Name eflowProducts -Value @{
    "Azure IoT Edge LTS"           = "https://aka.ms/AzEflowMSI"
    "Azure IoT Edge CR X64"        = "https://aka.ms/AzEFLOWMSI-CR-X64"
    "Azure IoT Edge CR ARM64"      = "https://aka.ms/AzEFLOWMSI-CR-ARM64"
    "Azure IoT Edge 1.4 LTS X64"   = "https://aka.ms/AzEFLOWMSI_1_4_LTS_X64"
    "Azure IoT Edge 1.4 LTS ARM64" = "https://aka.ms/AzEFLOWMSI_1_4_LTS_ARM64"
    "Azure IoT Edge 1.5 LTS X64"   = "https://aka.ms/AzEFLOWMSI_1_5_LTS_X64"
}

New-Variable -Option Constant -ErrorAction SilentlyContinue -Name eflowProvisioningProperties -Value @{
    "ManualConnectionString" = @("devConnString")
    "ManualX509"             = @("iotHubHostname", "deviceId", "identityCertPath", "identityPrivKeyPath")
    "DpsTPM"                 = @("scopeId")
    "DpsX509"                = @("scopeId", "identityCertPath", "identityPrivKeyPath")
    "DpsSymmetricKey"        = @("scopeId", "symmKey", "registrationId")
}

function Test-AdminRole {
    If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
                [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Error: This module requires Administrator mode!" -ForegroundColor Red
        return $false
    }
    return $true
}

function Get-HostPcInfo {
    Write-Host "Running eflowAutoDeploy version $eflowAutoDeployVersion"
    $pOS = Get-CimInstance Win32_OperatingSystem
    $UBR = (Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name UBR)
    $eadSession.HostOS.Name = $pOS.Caption
    $eadSession.HostOS.Version = "$($pOS.Version).$UBR"
    Write-Host "HostOS`t: $($pOS.Caption)($($pOS.OperatingSystemSKU)) `nVersion`t: $($eadSession.HostOS.Version) `nLang`t: $($pOS.MUILanguages) `nName`t: $($pOS.CSName)"
    #ProductTypeDomainController -Value 2 , #ProductTypeServer -Value 3
    $eadSession.HostPC.Name = $pOS.CSName
    $eadSession.HostOS.IsServerSKU = ($pOS.ProductType -eq 2 -or $pOS.ProductType -eq 3)
    $eadSession.HostPC.FreeMem = [Math]::Round($pOS.FreePhysicalMemory / 1MB) # convert kilo bytes to GB
    $pCS = Get-WmiObject -Class Win32_ComputerSystem
    $eadSession.HostPC.TotalMem = [Math]::Round($pCS.TotalPhysicalMemory / 1GB)
    $eadSession.HostPC.TotalCPU = $pCS.numberoflogicalprocessors
    Write-Host "Total CPUs`t`t: $($eadSession.HostPC.TotalCPU)"
    Write-Host "Free RAM / Total RAM`t: $($eadSession.HostPC.FreeMem) GB / $($eadSession.HostPC.TotalMem) GB"
    $pCDrive = (Get-WmiObject Win32_LogicalDisk ) | Where-Object { $_.DeviceID -eq 'C:' } #Get the C device size
    $eadSession.HostPC.FreeDisk = [Math]::Round($pCDrive.Freespace / 1GB) # convert bytes into GB
    $eadSession.HostPC.TotalDisk = [Math]::Round($pCDrive.Size / 1GB) # convert bytes into GB
    Write-Host "Free Disk / Total Disk`t: $($eadSession.HostPC.FreeDisk) GB / $($eadSession.HostPC.TotalDisk) GB"
    if ((Get-CimInstance Win32_BaseBoard).Product -eq 'Virtual Machine') {
        $eadSession.HostOS.IsVM = $true
        Write-Host "Running as a virtual machine " -NoNewline
        if (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue) {
            $eadSession.HostOS.IsAzureVM = $true
            Write-Host "in Azure environment " -NoNewline
        }
        if ($pCS.HypervisorPresent) {
            Write-Host "with Nested Hyper-V enabled"
            #(Get-VMProcessor -VM $vm).ExposeVirtualizationExtensions
        }
        else {
            Write-Host "without Nested Hyper-V" -ForegroundColor Red
        }
    }
    Get-EadEflowInstalledVersion | Out-Null
}

function Get-EadUserConfig {
    if ($null -eq $eadSession.UserConfig) {
        Write-Host "Error: EFLOW UserConfig is not set." -ForegroundColor Red
    }
    return $eadSession.UserConfig
}

function Read-EadUserConfig {
    if ($eadSession.UserConfigFile) {
        $eadSession.UserConfig = Get-Content "$($eadSession.UserConfigFile)" | ConvertFrom-Json

        # Remove unncesary empty network parameters
        $eadSession.UserConfig.network.PSObject.Properties | ForEach {
            if ($_.TypeNameOfValue -is [System.String] -and [string]::IsNullOrEmpty($_.Value)) {
                $eadSession.UserConfig.network.PSObject.Properties.Remove($_.Name)
            }
        }
    }
    else { Write-Host "Error: EFLOWUserConfigFile not configured" -ForegroundColor Red }
}

function Set-EadUserConfig {
    <#
    .DESCRIPTION
        Check if there is a configuration file, and loads the JSON configuration
        into a variable
    #>
    Param
    (
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$eflowjson
    )

    if (!(Test-Path -Path "$eflowjson" -PathType Leaf)) {
        Write-Host "Incorrect json file: $eflowjson"
        return
    }
    Write-Host "Loading $eflowjson.."
    $eadSession.UserConfigFile = "$eflowjson"
    Read-EadUserConfig
}

function Test-EadUserConfigNetwork {
    <#
    .DESCRIPTION
        Checks the EFLOW user configuration needed for EFLOW Network setup
    #>
    $errCnt = 0
    $eflowConfig = Get-EadUserConfig
    # 0) Check Hyper-V status
    Test-HyperVStatus | Out-Null
    # 1) Check the virtual switch name
    $nwCfg = $eflowConfig.network
    if ($null -eq $nwCfg) {
        if ($eadSession.HostOS.IsServerSKU) {
            Write-Host "Error: Server SKU, requires Network configuration, see https://aka.ms/AzEFLOW-vSwitch" -ForegroundColor Red
            return $false
        }
        else {
            Write-Host "* Client SKU : No Network configuration specified. Default Switch will be used." -ForegroundColor Green
            return $true
        }
    }

    if ([string]::IsNullOrEmpty($nwCfg.vswitchName)) {
        if ($eadSession.HostOS.IsServerSKU) {
            Write-Host "Error: Server SKU, a virutal switch is needed - For more information about EFLOW virutal switch creation, see https://aka.ms/AzEFLOW-vSwitch" -ForegroundColor Red
            $errCnt += 1
        }
        else { Write-Host "* Client SKU : No virtual switch specified - Default Switch will be used." -ForegroundColor Green }
    }
    else { Write-Host "* Using virtual switch $($nwCfg.vswitchName)" -ForegroundColor Green }
    # Check if the virtual switch type and associated properties
    switch ($nwCfg.vSwitchType) {
        "Internal" {
            if (-not $eadSession.HostOS.IsServerSKU ) {
                Write-Host "Error: vSwitchType is incorrect. Supported types : External (Client and Server) and Internal (Server)" -ForegroundColor Red
                $errCnt += 1
            }
            else { Write-Host "* Using vSwitchType Internal" -ForegroundColor Green }
        }
        "External" {
            if ([string]::IsNullOrEmpty($nwCfg.adapterName)) {
                Write-Host "Error: adapterName required for External switch" -ForegroundColor Red
                $errCnt += 1
            }
            else {
                $nwadapters = (Get-NetAdapter -Physical) | Where-Object { $_.Status -eq 'Up' -and $_.ConnectorPresent } | Select-Object -First 1
                if ($nwadapters.Name -notcontains ($nwCfg.adapterName)) {
                    Write-Host "Error: $($nwCfg.adapterName) not found. External switch creation will fail." -ForegroundColor Red
                    $errCnt += 1
                }
                else { Write-Host "* Using vSwitchType External" -ForegroundColor Green }
            }
        }
        default {
            if ($eadSession.HostOS.IsServerSKU ) {
                Write-Host "Error: vSwitchType is incorrect. Supported types : External (Client and Server) and Internal (Server)" -ForegroundColor Red
                $errCnt += 1
            }
            else { Write-Host "* Using vSwitchType Default" -ForegroundColor Green }
        }
    }

    # 3) Check the virtual switch IP address allocation
    Write-Host "--- Verifying virtual switch IP address allocation..."
    if ([string]::IsNullOrEmpty($nwCfg.ip4Address) -and
        [string]::IsNullOrEmpty($nwCfg.ip4GatewayAddress) -and
        [string]::IsNullOrEmpty($nwCfg.ip4PrefixLength)) {
        Write-Host "* No static IP address provided - DHCP allocation or auto-static ip(internal switch) will be used" -ForegroundColor Green
    }
    elseif ([string]::IsNullOrEmpty($nwCfg.ip4Address) -or
        [string]::IsNullOrEmpty($nwCfg.ip4GatewayAddress) -or
        [string]::IsNullOrEmpty($nwCfg.ip4PrefixLength)) {
        Write-Host "Error: IP4Address, IP4GatewayAddress and IP4PrefixLength parameters are needed" -ForegroundColor Red
        $errCnt += 1
    }
    else {
        $ipconfigstatus = $true
        if (-not ($nwCfg.ip4Address -as [IPAddress] -as [Bool])) {
            Write-Host "Error: Invalid IP4Address $($nwCfg.ip4Address)" -ForegroundColor Red
            $errCnt += 1
            $ipconfigstatus = $false
        }
        else {
            #Ping IP to ensure it is free
            $status = Test-Connection $nwCfg.ip4Address -Count 1 -Quiet
            if ($status) {
                Write-Host "Error: ip4Address $($nwCfg.ip4Address) in use" -ForegroundColor Red
                $errCnt += 1
                $ipconfigstatus = $false
            }
        }

        if (-not ($nwCfg.ip4GatewayAddress -as [IPAddress] -as [Bool])) {
            Write-Host "Error: Invalid IP4GatewayAddress $($nwCfg.ip4GatewayAddress)" -ForegroundColor Red
            $errCnt += 1
            $ipconfigstatus = $false
        }
        else {
            $status = Test-Connection $nwCfg.ip4GatewayAddress -Count 1 -Quiet
            if ((-not $status) -and ($nwCfg.vSwitchType -ieq "External")) {
                Write-Host "Error: ip4GatewayAddress $($nwCfg.ip4GatewayAddress) is not reachable. Required for external switch" -ForegroundColor Red
                $errCnt += 1
                $ipconfigstatus = $false
            }
        }

        [IPAddress]$mask = "255.255.255.0"
        if ( (([IPAddress]$nwCfg.ip4GatewayAddress).Address -band $mask.Address ) -ne (([IPAddress]$nwCfg.ip4Address).Address -band $mask.Address)) {
            Write-Host "Error: ip4GatewayAddress and ip4Address are not in the same subnet" -ForegroundColor Red
            $errCnt += 1
            $ipconfigstatus = $false
        }
        if ($nwCfg.ip4PrefixLength -as [int] -lt 0 -and $nwCfg.ip4PrefixLength -as [int] -ge 32) {
            Write-Host "Error: Invalid IP4PrefixLength $($nwCfg.ip4PrefixLength). Should be an integer between 0 and 32" -ForegroundColor Red
            $errCnt += 1
            $ipconfigstatus = $false
        }
        if ($ipconfigstatus) {
            Write-Host "* Using virtual switch with IP4Address: $($nwCfg.ip4Address)" -ForegroundColor Green
            Write-Host "                     ip4GatewayAddress: $($nwCfg.ip4GatewayAddress)" -ForegroundColor Green
            Write-Host "                          PrefixLength: $($nwCfg.ip4PrefixLength)" -ForegroundColor Green
        }
    }
    #TODO : Ping dnsServers for reachability. No Tests for http proxies
    Write-Host "--- Checking proxy settings..."
    if ($nwCfg.useHostProxy) {
        Write-Host "useHostProxy is set, ignoring httpProxy, httpsProxy, ftpProxy settings"
        $hostSettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyServer, ProxyEnable
        if ($hostSettings.ProxyEnable) {
            Write-Host "Using $($hostSettings.ProxyServer) as proxy settings"
        }
        else {
            Write-Host "Warning: useHostProxy is set, but no proxy setting found in host." -ForegroundColor Yellow
        }
    }
    else {
        if (![string]::IsNullOrEmpty($nwCfg.httpProxy) -and $nwCfg.httpProxy -NotLike "http://*") {
            Write-Host "Error: The httpProxy address $($nwCfg.httpProxy) is not valid." -ForegroundColor Red
            $errCnt += 1
        }
        if (![string]::IsNullOrEmpty($nwCfg.httpsProxy) -and $nwCfg.httpsProxy -NotLike "https://*") {
            Write-Host "Error: The httpsProxy address $($nwCfg.httpsProxy) is not valid." -ForegroundColor Red
            $errCnt += 1
        }
        if (![string]::IsNullOrEmpty($nwCfg.ftpProxy) -and $nwCfg.ftpProxy -NotLike "ftp://*") {
            Write-Host "Error: The ftpProxy address $($nwCfg.ftpProxy) is not valid." -ForegroundColor Red
            $errCnt += 1
        }
    }

    $retval = $true
    if ($errCnt) {
        Write-Host "$errCnt errors found in the Network Configuration. Fix errors before deployment" -ForegroundColor Red
        $retval = $false
    }
    else {
        Write-Host "*** No errors found in the Network Configuration." -ForegroundColor Green
    }
    return $retval
}

function Test-EadUserConfigInstall {
    $errCnt = 0
    $eflowConfig = Get-EadUserConfig
    Write-Host "`n--- Verifying EFLOW Install Configuration..."

    # 1) Check the product requested is valid
    if ($Script:eflowProducts.ContainsKey($eflowConfig.eflowProduct)) {
        if ($eadSession.EFLOW.Product) {
            #if already installed, check if they match
            if ($eadSession.EFLOW.Product -ne $eflowConfig.eflowProduct) {
                Write-Host "Error: Installed product $($eadSession.EFLOW.Product) does not match requested product $($eflowConfig.eflowProduct)." -ForegroundColor Red
                $errCnt += 1
            }
            else { Write-Host "* $($eflowConfig.eflowProduct) is installed" -ForegroundColor Green }
        }
        else { Write-Host "* $($eflowConfig.eflowProduct) to be installed" -ForegroundColor Green }
    }
    else {
        Write-Host "Error: Incorrect eflowProduct." -ForegroundColor Red
        Write-Host "Supported products: [$($Script:eflowProducts.Keys -join ',' )]"
        $errCnt += 1
    }
    # 2) Check if ProductUrl is valid if specified
    if (-not [string]::IsNullOrEmpty($eflowConfig.eflowProductUrl) -and
    (-not ([system.uri]::IsWellFormedUriString($eflowConfig.eflowProductUrl, [System.UriKind]::Absolute)))) {
        Write-Host "Error: eflowProductUrl is incorrect. $($eflowConfig.eflowProductUrl)." -ForegroundColor Red
        $errCnt += 1
    }
    # 3) Check if the install options are proper
    $installOptions = $eflowConfig.installOptions
    if ($installOptions) {
        $installOptItems = @("installPath", "vhdxPath")
        foreach ($item in $installOptItems) {
            $path = $installOptions[$item]
            if (-not [string]::IsNullOrEmpty($path) -and
            (-not (Test-Path -Path $path -IsValid))) {
                Write-Host "Error: Incorrect item. : $path" -ForegroundColor Red
                $errCnt += 1
            }
        }
    }
    $retval = $true
    if ($errCnt) {
        Write-Host "$errCnt errors found in the Install Configuration. Fix errors before Install" -ForegroundColor Red
        $retval = $false
    }
    else {
        Write-Host "*** No errors found in the Install Configuration." -ForegroundColor Green
    }
    return $retval
}

function Test-EadUserConfigDeploy {
    <#
    .DESCRIPTION
        Checks the EFLOW user configuration needed for EFLOW VM deployment
        Return $true if no blocking errors are found, and $false otherwise
    #>
    $errCnt = 0
    $eflowConfig = Get-EadUserConfig
    $euCfg = $eflowConfig.enduser
    Write-Host "`n--- Verifying EFLOW VM Deployment Configuration..."
    # 1) Check Mandatory configuration EULA
    Write-Host "--- Verifying EULA and telemetry..."
    if (($euCfg.acceptEula) -and ($euCfg.acceptEula -eq "Yes")) {
        Write-Host "* EULA accepted." -ForegroundColor Green
    }
    else {
        Write-Host "Error: Missing/incorrect mandatory EULA acceptance. Set acceptEula Yes" -ForegroundColor Red
        $errCnt += 1
    }

    if (($euCfg.acceptOptionalTelemetry) -and ($euCfg.acceptOptionalTelemetry -eq "Yes")) {
        Write-Host "* Optional telemetry accepted." -ForegroundColor Green
    }
    else {
        Write-Host "- Optional telemetry not accepted. Basic telemetry will be sent." -ForegroundColor Yellow
    }

    # 2) Check the virtual switch specified
    Write-Host "--- Verifying virtual switch..."
    if (-not (Test-EadEflowVmSwitch)) {
        $errCnt += 1
    }

    # 3) Check the virtual switch memory, cpu, and storage
    $vmCfg = $eflowConfig.vmConfig
    Write-Host "--- Verifying virtual machine resources..."

    if ($vmCfg.cpuCount -gt 0) {
        Write-Host "* Virtual machine will be created with $($vmCfg.cpuCount) vCPUs."
    }
    else {
        Write-Host "* No custom vCPUs used - Using default configuration, virtual machine will be created with 1 vCPUs."
        if ($vmCfg) { $vmCfg.PSObject.properties.remove('cpuCount') }
    }

    if ($vmCfg.memoryInMB -gt 0) {
        Write-Host "* Virtual machine will be created with $($vmCfg.memoryInMB) MB of memory."
    }
    else {
        Write-Host "* No custom memory used - Using default configuration, virtual machine will be created with 1024 MB of memory."
        if ($vmCfg) { $vmCfg.PSObject.properties.remove('memoryInMB') }
    }

    if ($vmCfg.vmDiskSize) {
        $lowerLimit = 21
        if ($eflowConfig.eflowProduct -ieq "Azure IoT Edge LTS") { $lowerLimit = 8 }
        if (($vmCfg.vmDiskSize -ge $lowerLimit) -and ($vmCfg.vmDiskSize -le 2000)) {
            #Between $lowerLimit GB and 2 TB
            Write-Host "* Virtual machine VHDX will be created with $($vmCfg.vmDiskSize) GB disk size."
        }
        else {
            Write-Host "Error: vmDiskSize should be between $lowerLimit GB and 2000 GB(2TB)" -ForegroundColor Red
            $errCnt += 1
        }
    }
    else {
        Write-Host "* No custom disk size used - Using default configuration, virtual machine VHDX will be created with 29 GB of disk size."
        if ($vmCfg) { $vmCfg.PSObject.properties.remove('vmDiskSize') }
    }
    if ($eflowConfig.eflowProduct -ieq "Azure IoT Edge LTS") {
        if ($vmCfg.vmDataSize -gt 0) {
            Write-Host "Error: vmDataSize is not supported in Azure IoT Edge LTS" -ForegroundColor Red
            $errCnt += 1
        }
    }
    else {
        if ($vmCfg.vmDataSize) {
            if (($vmCfg.vmDataSize -ge 2) -and ($vmCfg.vmDataSize -le 2000)) {
                #Between 2 GB and 2 TB
                Write-Host "* Virtual machine VHDX will be created with $($vmCfg.vmDataSize) GB of data size."
            }
            else {
                Write-Host "Error: vmDataSize should be between 2 GB and 2000 GB(2TB)" -ForegroundColor Red
                $errCnt += 1
            }
        }
        else {
            Write-Host "* No custom data size used - Using default configuration, virtual machine VHDX will be created with 10 GB of data size."
            if ($vmCfg) { $vmCfg.PSObject.properties.remove('vmDataSize') }
        }
    }
    if ($vmCfg.vmDataSize -and $vmCfg.vmDiskSize) {
        Write-Host "Error: Both vmDataSize and vmDiskSize specified. Specify one." -ForegroundColor Red
        $errCnt += 1
    }

    # 4) Check GPU passthrough configuration
    Write-Host "--- Verifying GPU passthrough configuration..."
    if ([string]::IsNullOrEmpty($vmCfg.gpuPassthroughType)) {
        Write-Host "* No GPU passthrough being used - CPU only allocation"
        if ($vmCfg) {
            $vmCfg.PSObject.properties.remove('gpuPassthroughType')
            $vmCfg.PSObject.properties.remove('gpuName')
            $vmCfg.PSObject.properties.remove('gpuCount')
        }
    }
    else {
        if ($vmCfg.gpuPassthroughType -ne 'DirectDeviceAssignment' -and $vmCfg.gpuPassthroughType -ne 'ParaVirtualization') {
            Write-Host "Error: GpuPassthrough type is invalid - Supported types: DirectDeviceAssignment or ParaVirtualization" -ForegroundColor Red
            $errCnt += 1
        }
        else { Write-Host "* $($vmCfg.gpuPassthroughType) specified" -ForegroundColor Green }

        if ([string]::IsNullOrEmpty($vmCfg.gpuName)) {
            Write-Host "Error: GpuName must be provided" -ForegroundColor Red
            $errCnt += 1
        }
    }
    if ($vmCfg -and $null -eq $vmCfg.PSObject.properties.Name) {
        $eflowConfig.PSObject.properties.remove('vmConfig')
    }
    $retval = $true
    if ($errCnt) {
        Write-Host "$errCnt errors found in the Deployment Configuration. Fix errors before deployment" -ForegroundColor Red
        $retval = $false
    }
    else {
        Write-Host "*** No errors found in the Deployment Configuration." -ForegroundColor Green
    }
    return $retval
}

function Test-EadUserConfigProvision {
    <#
    .DESCRIPTION
        Checks the EFLOW user configuration needed for EFLOW provisioning
    #>
    $errCnt = 0
    $eflowConfig = Get-EadUserConfig
    $provCfg = $eflowConfig.eflowProvisioning
    if ($null -eq $provCfg) {
        Write-Host "- Provisioning Configuration not specified." -ForegroundColor Yellow
        return $false
    }
    Write-Host "`n--- Verifying EFLOW VM Provisioning Configuration..."
    # 1) Check provisioning type
    Write-Host "--- Verifying provisioning type..."

    if (-not $Script:eflowProvisioningProperties.ContainsKey($provCfg.provisioningType)) {
        Write-Host "Error: provisioningType is incorrect or not specified.`nSupported provisioningType: [$($Script:eflowProvisioningProperties.Keys)]" -ForegroundColor Red
        $errCnt += 1
    }
    else {
        Write-Host "* $($provCfg.provisioningType)" -ForegroundColor Green
    }

    # 2) Check parameters required for the provisioning type
    Write-Host "--- Verifying provisioning parameters.."
    $reqSettings = $Script:eflowProvisioningProperties[$provCfg.provisioningType]
    if ($reqSettings) {
        #if we have valid parameter array
        foreach ($setting in $reqSettings) {
            #verify if the parameters are specified
            $value = $provCfg.$setting
            if ($value) {
                # Not writing out the value as it may have credentials that we dont want in logs
                Write-Host "* $setting Ok" -ForegroundColor Green
                #if parameter contains path, ensure that the file is present
                if ($setting.Contains("Path")) {
                    if (-not (Test-Path -Path $value -PathType Leaf)) {
                        Write-Host "Error: File not found :$value" -ForegroundColor Red
                        $errCnt += 1
                    }
                }
            }
            else {
                Write-Host "Error: provisioningType $($provCfg.provisioningType) requires $setting value." -ForegroundColor Red
                $errCnt += 1
            }
        }
    }

    $retval = $true
    if ($errCnt) {
        Write-Host "$errCnt errors found in the Provisioning Configuration. Fix errors before deployment" -ForegroundColor Red
        $retval = $false
    }
    else {
        Write-Host "No errors found in the Provisioning Configuration." -ForegroundColor Green
    }
    return $retval
}

function Test-EadUserConfig {

    $installResult = Test-EadUserConfigInstall
    $deployResult = Test-EadUserConfigDeploy
    $provResult = Test-EadUserConfigProvision

    return ($installResult -and $deployResult -and $provResult)

}

function Test-EadEflowInstall {
    Param
    (
        [Switch] $Install
    )

    $eflowVersion = Get-EadEflowInstalledVersion

    if ($null -eq $eflowVersion) {
        if (!$Install) { return $false }
        if (-not (Invoke-EadEflowInstall)) { return $false }
    }
    $mod = Get-Module -Name AzureEFLOW
    #check if module is loaded
    if (!$mod) {
        Write-Host "Importing AzureEFLOW.."
        Import-Module -Name AzureEFLOW -Force
    }
    $version = (Get-Module -Name AzureEFLOW).Version.ToString()
    Write-Host "AzureEFLOW Module:$version"
    return $true
}

function Test-HyperVStatus {
    Param
    (
        [Switch] $Enable
    )
    $retval = $true
    #Enable HyperV
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
    if ($feature.State -ne "Enabled") {
        $retval = $false
        Write-Host "Hyper-V is disabled" -ForegroundColor Red
        if ($Enable) {
            Write-Host "Enabling Hyper-V"
            if ($eadSession.HostOS.IsServerSKU) {
                Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools
            }
            else {
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
            }
            Write-Host "Rebooting machine for enabling Hyper-V" -ForegroundColor Yellow
            Restart-Computer -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Host "Hyper-V is enabled" -ForegroundColor Green
    }
    return $retval
}

function Test-EadEflowVmProvision {
    <#
    .DESCRIPTION
        Checks if the EFLOW VM is provisioned
    #>
    $retval = $true
    if (Test-EadEflowVmRun) {
        $command = "if [[ `$(sudo sha256sum /etc/iotedge/config.yaml  | cut -f1 -d' ') == `$(sudo sha256sum /var/.eflow/config/config.yaml  | cut -f1 -d' ') ]]; then echo clean; fi"
        $ret = Invoke-EflowVmCommand -command $command
        if ($ret -like "clean") { $retval = $false }
        else {
            Write-Host "config.yaml is not default. EFLOW VM maybe provisioned earlier." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Error: Eflow VM is not running. Cannot determine provisioning status." -ForegroundColor Red
    }
    return $retval
}

function Test-EadEflowVmRun {
    <#
    .DESCRIPTION
        Checks if the EFLOW VM is running
    #>
    $retval = $false
    if ($eadSession.HostOS.IsServerSKU) {
        $vm = Get-VM | Where-Object { $_.Name -like '*EFLOW' }
        if ($vm -and ($vm.State -ieq 'Running')) { $retval = $true }

    }
    else {
        $found = (hcsdiag list) | Select-String -Pattern 'wssdagent'
        <# hcsdiag list -raw supported only in later windows versions
        $pVMList = (hcsdiag list -raw) | ConvertTo-Json -ErrorAction SilentlyContinue
        $found = $pVMList | Where-Object { $_.Owner -like 'wssdagent'}
        #>
        if ($found) { $retval = $true }
    }
    return $retval
}

function Test-EadEflowVmDeploy {
    <#
    .DESCRIPTION
        Checks if the EFLOW VM is deployed (checking vhdx is present)
    #>
    $vhdxPath = "C:\\Program Files\\Azure IoT Edge"
    $eflowConfig = Get-EadUserConfig
    if ($eflowConfig.installOptions.vhdxPath) {
        $vhdxPath = $eflowConfig.installOptions.vhdxPath
    }
    $retval = Test-Path -Path $vhdxPath\*EFLOW.vhdx

    return $retval
}

function Invoke-EadEflowInstall {
    <#
    .DESCRIPTION
        Checks if EFLOW MSI is installed, and installs it if not
    #>
    #TODO : Add Force flag to uninstall and install req product
    if ($eadSession.EFLOW.Version) {
        Write-Host "$($eadSession.EFLOW.Product)-$($eadSession.EFLOW.Version) is already installed"
        return $true
    }
    $eflowConfig = Get-EadUserConfig
    if ($null -eq $eflowConfig) { return $retval }
    if (-not (Test-EadUserConfigInstall)) { return $false } # bail if the validation failed
    $reqProduct = $eflowConfig.eflowProduct
    $url = $Script:eflowProducts[$reqProduct]
    if ($eflowConfig.eflowProductUrl) {
        $url = $eflowConfig.eflowProductUrl
    }
    Write-Host "Installing $reqProduct from $url"
    
    $outInstallPath = "$PSScriptRoot\AzureIoTEdge.msi"

    # BSINGH - Custom  check for existing MSI file
    if (Test-Path -Path $outInstallPath) {
        Write-Host "Using existing AzureIoTEdge.msi file"
    }
    else {
        Write-Host "Downloading AzureIoTEdge.msi..."
        Download-File -Url $url -OutFile $outInstallPath
    }

    $argList = "/I $outInstallPath /qn "
    if ($eflowConfig.installOptions) {
        $installPath = $eflowConfig.installOptions.installPath
        if ($installPath) {
            $argList = $argList + "INSTALLDIR=""$($installPath)"" "
        }
        $vhdxPath = $eflowConfig.installOptions.vhdxPath
        if ($vhdxPath) {
            $argList = $argList + "VHDXDIR=""$($vhdxPath)"" "
        }
    }
    Write-Host $argList
    Start-Process msiexec.exe -Wait -ArgumentList $argList
    # Remove-Item .\AzureIoTEdge.msi
    $ProgressPreference = 'Continue'
    Write-Host "$reqProduct successfully installed"
    return $true
}

# Function to download a file from a URL
function Download-File {
    param (
        [string]$url,
        [string]$outFile
    )

    function convertFileSize {
        param(
            $bytes
        )
    
        if ($bytes -lt 1MB) {
            return "$([Math]::Round($bytes / 1KB, 2)) KB"
        }
        elseif ($bytes -lt 1GB) {
            return "$([Math]::Round($bytes / 1MB, 2)) MB"
        }
        elseif ($bytes -lt 1TB) {
            return "$([Math]::Round($bytes / 1GB, 2)) GB"
        }
    }

    try {
        
        $outPath = $outFile
        Write-Host "Downloading $url to $outPath..."
        
        $webClient = New-Object -TypeName System.Net.WebClient
        $webClient.Credentials = $login
        
        Unregister-Event -SourceIdentifier WebClient.DownloadProgressChanged -ErrorAction SilentlyContinue
        Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -SourceIdentifier WebClient.DownloadProgressChanged | Out-Null
        
        $startTime = Get-Date
        $lastBytesReceived = 0
        $task = $webClient.DownloadFileTaskAsync($url, $outPath)
        
        Start-Sleep -Seconds 1
        
        while (!($task.IsCompleted)) {

            # Check if any download progress events have been raised
            if (Get-Event -SourceIdentifier WebClient.DownloadProgressChanged -ErrorAction SilentlyContinue) {
        
                $EventData = Get-Event -SourceIdentifier WebClient.DownloadProgressChanged | Select-Object -ExpandProperty "SourceEventArgs" -Last 1
        
                $ReceivedData = ($EventData | Select-Object -ExpandProperty "BytesReceived")
                $TotalToReceive = ($EventData | Select-Object -ExpandProperty "TotalBytesToReceive")
                $TotalPercent = $EventData | Select-Object -ExpandProperty "ProgressPercentage"
        
                $currentTime = Get-Date
                $elapsedTime = New-TimeSpan -Start $startTime -End $currentTime
                $bytesReceivedSinceLastUpdate = $ReceivedData - $lastBytesReceived
                $speedKBps = [Math]::Round($bytesReceivedSinceLastUpdate / $elapsedTime.TotalSeconds / 1KB, 2)
        
                Start-Sleep -Milliseconds 200
        
                Write-Progress -Activity "Downloading File" -Status "Percent Complete: $($TotalPercent)%, Speed: $($speedKBps) KB/s" -CurrentOperation "Downloaded $(convertFileSize -bytes $ReceivedData) / $(convertFileSize -bytes $TotalToReceive)" -PercentComplete $TotalPercent

                $startTime = $currentTime
                $lastBytesReceived = $ReceivedData
            }
            else {
                # If no events have been raised yet, sleep for a short time before checking again
                Start-Sleep -Milliseconds 500
            }
        }
        
        Unregister-Event -SourceIdentifier WebClient.DownloadProgressChanged
        $webClient.Dispose()
    }
    catch {
        Write-Error "Error downloading file: $($_.Exception.Message)"
    }
    finally {
        # Ensure the WebClient is disposed of
        if ($webClient) {
            $webClient.Dispose()
        }
    }
}

function Remove-EadEflowInstall {
    <#
   .DESCRIPTION
       Checks if EFLOW MSI is installed, and removes it if installed
   #>
    $eflowInfo = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' | Get-ItemProperty |  Where-Object { $_.DisplayName -match 'Azure IoT Edge *' }
    if ($null -eq $eflowInfo) {
        Write-Host "Azure IoT Edge is not installed."
    }
    else {
        Write-Host "$($eflowInfo.DisplayName) version $($eflowInfo.DisplayVersion) is installed. Removing..."
        Start-Process msiexec.exe -Wait -ArgumentList "/x $($eflowInfo.PSChildName) /quiet /noreboot"
        # Remove the module from Powershell session as well
        Remove-Module -Name AzureEFLOW -Force
        $eadSession.EFLOW.Product = $null
        $eadSession.EFLOW.Version = $null
        Write-Host "$($eflowInfo.DisplayName) successfully removed."
    }
}

function Get-EadEflowInstalledVersion {
    <#
   .DESCRIPTION
       Gets EFLOW version if installed
   #>
    $eflowInfo = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' | Get-ItemProperty |  Where-Object { $_.DisplayName -match 'Azure IoT Edge *' }
    $retval = $null
    if ($null -eq $eflowInfo) {
        Write-Host "Azure IoT Edge is not installed."
    }
    else {
        $retval = "$($eflowInfo.DisplayName),$($eflowInfo.DisplayVersion)"
        $eadSession.EFLOW.Version = $eflowInfo.DisplayVersion
        $eadSession.EFLOW.Product = $eflowInfo.DisplayName
        Write-Host "$retval is installed."
    }
    return $retval
}

function Invoke-EadEflowDeploy {
    <#
    .DESCRIPTION
        Loads the configuration and tries to deploy the EFLOW VM
    #>
    if (Test-EadEflowVmDeploy) {
        Write-Host "Error: Eflow VM already deployed" -Foreground red
        return $false
    }
    if (-not (Test-EadUserConfigDeploy)) { return $false }
    $eflowDeployParams = @{}
    $eflowConfig = Get-EadUserConfig
    #Properties are validated. So just add here
    $eflowDeployParams.Add("acceptEula", "Yes")
    if ($eflowConfig.enduser.acceptOptionalTelemetry -eq "Yes") {
        $eflowDeployParams.Add("acceptOptionalTelemetry", "Yes")
    } 
    elseif ($eflowConfig.enduser.acceptOptionalTelemetry -eq "No") {
        $eflowDeployParams.Add("acceptOptionalTelemetry", "No")
    }

    if ($eflowConfig.network) {
        #network params are optional for Client using default switch
        $reqProperties = @("vswitchName", "vswitchType", "ip4Address", "ip4GatewayAddress", "ip4PrefixLength")
        foreach ($property in $($eflowConfig.network).PSObject.Properties) {
            if ($reqProperties -contains $property.Name) {
                $eflowDeployParams.Add($property.Name, $property.Value)
            }
        }
    }
    if ($eflowConfig.vmConfig) {
        #vmConfig params are optional
        foreach ($property in $($eflowConfig.vmConfig).PSObject.Properties) {
            $eflowDeployParams.Add($property.Name, $property.Value)
        }
    }

    Write-Verbose "EFLOW VM deployment parameters..."
    Write-Verbose ($eflowDeployParams | Out-String)

    #TODO - Check if eflow is deployed previously before attempting to deploy again.
    Write-Host "Starting EFLOW VM deployment..."
    $retval = Deploy-Eflow @eflowDeployParams

    if ($retval -ieq "OK") {
        Write-Host "* EFLOW VM deployment successfull." -ForegroundColor Green
    }
    else {
        Write-Host "Error: EFLOW VM deployment failed with the below error message." -ForegroundColor Red
        Write-Host "Error message : $retval." -ForegroundColor Red
        return $false
    }

    #Set-EflowVmDnsServers
    if ($eflowConfig.network.dnsServers) {
        Write-Host "Setting DNS Servers to $($eflowConfig.network.dnsServers)"
        Set-EflowVmDNSServers -dnsServers $eflowConfig.network.dnsServers
    }
    # If using Static IP and no DnsServer is provided, use main interface DNS servers
    elseif ($eflowConfig.network.vswitchType -eq "Internal") {
        # Get DNS servers including gateway
        Write-Host "Looking for available DNS Servers..."
        [String[]] $dnsservers = $(((Get-NetIPConfiguration | ForEach-Object IPv4DefaultGateway).NextHop))
        $dnsservers += $(Get-DnsClientServerAddress | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })
        $dnsservers = $dnsservers | Where-Object { -Not [string]::IsNullOrEmpty($_) } | Select-Object -uniq
        Write-Host "Setting DNS Servers to $dnsservers"
        Set-EflowVmDNSServers -dnsServers $dnsservers
    }

    #Set-EflowVmFeature
    if ($eflowConfig.vmFeature.DpsTpm) {
        Write-Host "Enabling vmFeature: DpsTpm"
        Set-EflowVmFeature -feature DpsTpm -enable
    }
    if ($eflowConfig.vmFeature.Defender) {
        Write-Host "Enabling vmFeature: Defender"
        Set-EflowVmFeature -feature Defender -enable
    }
    return $true
}

function Invoke-EadEflowProvision {
    <#
    .DESCRIPTION
        Loads the configuration and tries to provision the EFLOW VM
    #>
    if (-not (Test-EadEflowVmRun)) {
        Write-Host "Error: Eflow VM is not found" -ForegroundColor Red
        return $false
    }

    $retval = Test-EadUserConfigProvision
    if (-not $retval) { return $false }
    $eflowConfig = Get-EadUserConfig
    $provCfg = $eflowConfig.eflowProvisioning
    $eflowProvisionParams = @{
        "provisioningType" = $provCfg.provisioningType
    }
    $reqSettings = $Script:eflowProvisioningProperties[$provCfg.provisioningType]
    if ($reqSettings) {
        #if we have valid parameter array
        foreach ($setting in $reqSettings) {
            #get values for each required setting. No validation here as its done earlier
            $eflowProvisionParams.Add($setting, $provCfg.$setting)
        }
    }
    if ($provCfg.globalEndpoint) {
        $eflowProvisionParams.Add("globalEndpoint", $provCfg.globalEndpoint)
    }

    Write-Verbose "--- EFLOW VM provisioning parameters..."
    #Making this Verbose as we possibly show secure key/connection string in logs
    Write-Verbose ($eflowProvisionParams | Out-String)

    Write-Host "Starting EFLOW VM provisioning..."
    $retval = Provision-EflowVm @eflowProvisionParams -headless
    if ($retval -ieq "OK") {
        Write-Host "* EFLOW provisioning successfull." -ForegroundColor Green
        Start-Sleep 60 #wait a minute to allow iotedge initialize
    }
    else {
        Write-Host "Error: EFLOW provisioning failed with the below error message." -ForegroundColor Red
        Write-Host "Error message : $retval." -ForegroundColor Red
        return $false
    }
    return $true
}

function Invoke-EadEflowProxyConfiguration {
    <#
    .DESCRIPTION
        Loads the proxy configuration and tries to set up proxy on the VM
    #>
    if (-not (Test-EadEflowVmRun)) {
        Write-Host "Error: Eflow VM is not found" -ForegroundColor Red
        return $false
    }

    $proxyParams = @{}
    if ($eflowConfig.network.useHostProxy) {
        $hostSettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyServer, ProxyEnable
        if ($hostSettings.ProxyEnable) {
            $proxyParams.Add("httpsProxy", "$($hostSettings.ProxyServer)")
            $proxyParams.Add("httpProxy", "$($hostSettings.ProxyServer)")
        }
    }
    else {
        if ($eflowConfig.network.httpsProxy) {
            $proxyParams.Add("httpsProxy", "$($eflowConfig.network.httpsProxy)")
        }
        if ($eflowConfig.network.httpProxy) {
            $proxyParams.Add("httpProxy", "$($eflowConfig.network.httpProxy)")
        }
        if ($eflowConfig.network.ftpProxy) {
            $proxyParams.Add("ftpProxy", "$($eflowConfig.network.ftpProxy)")
        }
    }
    if ($proxyParams.Count) {
        Write-Host "Starting EFLOW VM Proxy configuration..." -ForegroundColor Green
        Set-EflowVmProxyServers @proxyParams
    }
    else {
        Write-Host "No proxy configuration found. Skipping EFLOW VM proxy configuration" -ForegroundColor Green
    }
    return $true
}

function Test-EadEflowProxyConfiguration {
    $proxyEnv = Invoke-EflowVmCommand 'echo $http_proxy $https_proxy'
    if ([string]::IsNullOrEmpty($proxyEnv)) {
        Write-Host "No EFLOW VM proxy configuration already applied" -ForegroundColor Green
        $retval = $false
    }
    else {
        Write-Host "Error: Eflow VM proxy already configured - Try manual configuration" - -ForegroundColor Red
        $retval = $true
    }
    return $retval
}

function Set-EflowVmProxyServers {
    # Configuration based on the following documents
    # https://learn.microsoft.com/en-us/azure/iot-edge/how-to-configure-proxy-support?view=iotedge-1.4
    param (
        [string] $httpProxy,
        [string] $httpsProxy,
        [string] $ftpProxy
    )
    if ([string]::IsNullOrEmpty($httpProxy) -and [string]::IsNullOrEmpty($httpsProxy) -and [string]::IsNullOrEmpty($ftpProxy)) {
        Write-Host "Either -httpProxy or -httpsProxy or -ftpProxy must be provided." -ForegroundColor Red
        return
    }
    $restartIotEdge = $false
    if (![string]::IsNullOrEmpty($httpProxy) -or ![string]::IsNullOrEmpty($httpsProxy)) {
        # Create the ovverride conf files
        Invoke-EflowVmCommand "sudo mkdir -p /etc/systemd/system/aziot-edged.service.d/ && sudo touch /etc/systemd/system/aziot-edged.service.d/override.conf && printf '[Service]' | sudo tee /etc/systemd/system/aziot-edged.service.d/override.conf > /dev/null"
        Invoke-EflowVmCommand "sudo mkdir -p /etc/systemd/system/aziot-identityd.service.d/ && sudo touch /etc/systemd/system/aziot-identityd.service.d/override.conf && printf '[Service]' | sudo tee /etc/systemd/system/aziot-identityd.service.d/override.conf > /dev/null"
        Invoke-EflowVmCommand "sudo mkdir -p /etc/systemd/system/docker.service.d/ && sudo touch /etc/systemd/system/docker.service.d/http-proxy.conf && printf '[Service]' | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null"
        Invoke-EflowVmCommand "sudo echo -e '\n[agent]\nname = \`"edgeAgent\`"\ntype = \`"docker\`"\n\n[agent.config]\nimage = \`"mcr.microsoft.com/azureiotedge-agent:latest\`"\ncreateOptions = { HostConfig = { Binds = [\`"/iotedge/storage:/iotedge/storage\`"] } }\n\n[agent.env]' | sudo tee -a /etc/aziot/config.toml > /dev/null"
        $restartIotEdge = $true
    }
    if (![string]::IsNullOrEmpty($httpProxy)) {
        Write-Host "Setting httpProxy configuration : $httpProxy"
        # Define the http_proxy environment variable
        Invoke-EflowVmCommand "sudo sed -i '/^export http_proxy/s.^.#.' /etc/bash.bashrc && echo export http_proxy=$httpProxy | sudo tee -a /etc/bash.bashrc > /dev/null && export http_proxy=$httpProxy"
        # Create overrride conf for the different aziot-edged service
        Invoke-EflowVmCommand "sudo printf  '\nEnvironment=http_proxy=$httpProxy' | sudo tee -a /etc/systemd/system/aziot-edged.service.d/override.conf > /dev/null"
        Invoke-EflowVmCommand "sudo printf  '\nEnvironment=http_proxy=$httpProxy' | sudo tee -a /etc/systemd/system/aziot-identityd.service.d/override.conf > /dev/null"
        Invoke-EflowVmCommand "sudo printf  '\nEnvironment=http_proxy=$httpProxy' | sudo tee -a /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null"
        Invoke-EflowVmCommand "sudo echo -e '\`"http_proxy\`" = \`"$httpProxy\`"' | sudo tee -a /etc/aziot/config.toml > /dev/null"
    }
    if (![string]::IsNullOrEmpty($httpsProxy)) {
        Write-Host "Setting httpsProxy configuration : $httpsProxy"
        # Define the http_proxy environment variable
        Invoke-EflowVmCommand "sudo sed -i '/^export https_proxy/s.^.#.' /etc/bash.bashrc && echo export https_proxy=$httpsProxy | sudo tee -a /etc/bash.bashrc > /dev/null && export https_proxy=$httpsProxy"
        # Create overrride conf for the different aziot-edged service
        Invoke-EflowVmCommand "sudo printf  '\nEnvironment=https_proxy=$httpsProxy' | sudo tee -a /etc/systemd/system/aziot-edged.service.d/override.conf > /dev/null"
        Invoke-EflowVmCommand "sudo printf  '\nEnvironment=https_proxy=$httpsProxy' | sudo tee -a /etc/systemd/system/aziot-identityd.service.d/override.conf > /dev/null"
        Invoke-EflowVmCommand "sudo printf  '\nEnvironment=https_proxy=$httpsProxy' | sudo tee -a /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null"
        Invoke-EflowVmCommand "sudo echo -e '\`"https_proxy\`" = \`"$httpsProxy\`"' | sudo tee -a /etc/aziot/config.toml > /dev/null"
    }
    if (![string]::IsNullOrEmpty($ftpProxy)) {
        Write-Host "Setting ftpProxy configuration : $ftpProxy"
        # Define the http_proxy environment variable
        Invoke-EflowVmCommand "sudo sed -i '/^export ftp_proxy/s.^.#.' /etc/bash.bashrc && echo export ftp_proxy=$ftpProxy | sudo tee -a /etc/bash.bashrc > /dev/null && export ftp_proxy=$ftpProxy"
    }
    if ($restartIotEdge) {
        Write-Host "Applying IoT Edge configuration and recreating EdgeAgent"
        Invoke-EflowVmCommand "sudo iotedge config apply && sudo docker rm -f edgeAgent"
        Write-Host "Restarting IoT Edge services"
        Invoke-EflowVmCommand "sudo systemctl daemon-reload && sudo iotedge system restart"
    }
}

function Test-EadEflowVmSwitch {
    Param
    (
        [Switch] $Create
    )
    $usrCfg = Get-EadUserConfig
    $nwCfg = $usrCfg.network
    if (! (Test-EadUserConfigNetwork)) { return $false }

    if ([string]::IsNullOrEmpty($nwCfg.vSwitchName)) {
        if (-not $eadSession.HostOS.IsServerSKU) {
            Write-Host "vSwitchName not specified. Checking Default switch."
            $defaultSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
            if ($defaultSwitch) {
                Write-Host "* Default switch found" -ForegroundColor Green
                $retval = $true
            }
            else {
                Write-Host "Error: Default switch not found" - -ForegroundColor Red
                $retval = $false
            }
            return $retval
        }
        Write-Host "Error: vSwitchName not specified. " -ForegroundColor Red
        return $false
    }
    # we have a name to check further..
    $eflowSwitch = Get-VMSwitch -Name $nwCfg.vSwitchName -ErrorAction SilentlyContinue

    if ($eflowSwitch) {
        #Switch is found. If it is internal, grab the IP details to pass
        if ($nwCfg.vSwitchType -ieq "Internal") {
            # check if nat is present as well
            $nat = Get-NetNat -Name "$($nwCfg.vSwitchName)-NAT"
            if ($nat) {
                # Nat already exists, grab the ip info
                $eflowSwitchAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "vEthernet ($($nwCfg.vSwitchName))" }
                $ifIndex = $eflowSwitchAdapter.ifIndex
                $switchIpAddress = (Get-NetIPAddress -AddressFamily IPv4  -InterfaceIndex $ifIndex).IPAddress
                $ipPrefix = ($switchIpAddress.Split('.')[0..2]) -join '.'
                Write-Host "* Internal Switch found with the ipPrefix $ipPrefix"
                if ($null -eq $nwCfg.ip4Address) {
                    # No ip address specified. So update those fields with the generated ones.
                    $nwCfg | Add-Member -MemberType NoteProperty -Name ip4GatewayAddress -Value $switchIpAddress
                    $nwCfg | Add-Member -MemberType NoteProperty -Name ip4Address -Value "$ipPrefix.2"
                    $nwCfg | Add-Member -MemberType NoteProperty -Name ip4PrefixLength -Value 24
                    Write-Host "Using EFLOW static IP4Address: $($nwCfg.ip4Address)" -ForegroundColor Green
                    Write-Host "           Gateway IP4Address: $($nwCfg.ip4GatewayAddress)" -ForegroundColor Green
                    Write-Host "                 PrefixLength: $($nwCfg.ip4PrefixLength)" -ForegroundColor Green
                }
            }
            else {
                # No Nat. Not in a good state, so either we auto delete and recreate or report error and bail
                # bailing out for now
                Write-Host "Error: Internal switch found. NAT not found. Delete switch and recreate." -ForegroundColor Red
                return $false
            }
        }
        Write-Host "* Name:$($eflowSwitch.Name) - Type:$($eflowSwitch.SwitchType)" -ForegroundColor Green
    }
    else {
        # no switch found. Create if requested
        if ($Create) {
            return New-EadEflowVmSwitch
        }
        Write-Host "Error: VMSwitch $($nwCfg.vSwitchName) not found." -ForegroundColor Red
        return $false
    }
    return $true
}

function New-EadEflowVmSwitch {
    $usrCfg = Get-EadUserConfig
    $nwCfg = $usrCfg.network

    $eflowSwitch = Get-VMSwitch -Name $nwCfg.vSwitchName -ErrorAction SilentlyContinue

    if ($eflowSwitch) {
        Write-Host "Error: Name:$($eflowSwitch.Name) - Type:$($eflowSwitch.SwitchType) already exists" -ForegroundColor Red
        return $false
    }
    # no switch found. Create if requested
    Write-Host "Creating VMSwitch $($nwCfg.vSwitchName) - $($nwCfg.vSwitchType)..."
    if ($nwCfg.vSwitchType -ieq "Internal") {
        $eflowSwitch = New-VMSwitch -SwitchType $nwCfg.vSwitchType -Name $nwCfg.vSwitchName -ErrorAction SilentlyContinue
        # give some time for the switch creation to succeed
        Start-Sleep 10
        $eflowSwitchAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vEthernet ($($nwCfg.vSwitchName))" }
        if ($null -eq $eflowSwitchAdapter) {
            Write-Host "Error: [vEthernet ($($nwCfg.vSwitchName))] is not found. $($nwCfg.vSwitchName) switch creation failed.  Please try switch creation again."
            return $false
        }

        if ($null -eq $nwCfg.ip4Address) {
            # No ip address specified. So update those fields with the generated ones.
            $ifIndex = $eflowSwitchAdapter.ifIndex
            $switchIpAddress = (Get-NetIPAddress -AddressFamily IPv4  -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue).IPAddress
            if (!$switchIpAddress) {
                Write-Host "Error: [vEthernet ($($nwCfg.vSwitchName))] IP address not found. IP assignment of the virtual switch $($nwCfg.vSwitchName) failed.  Please try switch creation again."
                return $false
            }
            $ipPrefix = ($switchIpAddress.Split('.')[0..2]) -join '.'
            $nwCfg | Add-Member -MemberType NoteProperty -Name ip4GatewayAddress -Value "$ipPrefix.1"
            $nwCfg | Add-Member -MemberType NoteProperty -Name ip4Address -Value "$ipPrefix.2"
            $nwCfg | Add-Member -MemberType NoteProperty -Name ip4PrefixLength -Value 24
        }

        $ipPrefix = ($nwCfg.ip4GatewayAddress.Split('.')[0..2]) -join '.'
        $natPrefix = "$ipPrefix.0/$($nwCfg.ip4PrefixLength)"

        New-NetIPAddress -IPAddress $nwCfg.ip4GatewayAddress -PrefixLength $nwCfg.ip4PrefixLength -InterfaceAlias "vEthernet ($($nwCfg.vSwitchName))" | Out-Null
        Write-Host "Using EFLOW static IP4Address: $($nwCfg.ip4Address)" -ForegroundColor Green
        Write-Host "           Gateway IP4Address: $($nwCfg.ip4GatewayAddress)" -ForegroundColor Green
        Write-Host "                 PrefixLength: $($nwCfg.ip4PrefixLength)" -ForegroundColor Green

        New-NetNat -Name "$($nwCfg.vSwitchName)-NAT" -InternalIPInterfaceAddressPrefix $natPrefix |  Out-Null
    }
    else {
        $nwadapters = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue) | Where-Object { $_.Status -eq 'Up' -and $_.ConnectorPresent } | Select-Object -First 1
        if ($nwadapters.Name -notcontains ($nwCfg.adapterName)) {
            Write-Host "Error: $($nwCfg.adapterName) not found. External switch not created." -ForegroundColor Red
            return $false
        }
        $eflowSwitch = New-VMSwitch -NetAdapterName $nwCfg.adapterName -Name $nwCfg.vSwitchName -ErrorAction SilentlyContinue
        # give some time for the switch creation to succeed
        Start-Sleep 10
        $eflowSwitchAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "vEthernet ($($nwCfg.vSwitchName))" }
        if ($null -eq $eflowSwitchAdapter) {
            Write-Host "Error: [vEthernet ($($nwCfg.vSwitchName))] is not found. $($nwCfg.vSwitchName) switch creation failed.  Please try switch creation again."
            return $false
        }
    }
    return $true
}

function Remove-EadEflowVmSwitch {
    $usrCfg = Get-EadUserConfig
    $switchName = $($usrCfg.network.vswitchName)
    $eflowSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($eflowSwitch) {
        Write-Host "Removing $switchName"
        Remove-VMSwitch -Name $switchName
        if ($eflowSwitch.SwitchType -ieq "Internal") {
            $eflowNat = Get-NetNat -Name "$switchName-NAT"
            if ($eflowNat) {
                Write-Host "Removing $switchName-NAT"
                Remove-NetNat -Name "$switchName-NAT"
            }
        }
    }
}

# Main function for full functional path
function Start-EadWorkflow {
    Param
    (
        [String]$eflowjson
    )
    # Validate input parameter. Use default json in the same path if not specified
    if ([string]::IsNullOrEmpty($eflowjson)) {
        $eflowjson = "$PSScriptRoot\eflow-userconfig.json"
    }

    if (!(Test-Path -Path "$eflowjson" -PathType Leaf)) {
        Write-Host "Error: $eflowjson not found" -ForegroundColor Red
        return $false
    }
    $eflowjson = (Resolve-Path -Path $eflowjson).Path
    Set-EadUserConfig $eflowjson # validate later after creating the switch
    # Check admin role
    if (!(Test-AdminRole)) { return $false }
    # Check PC prequisites (Hyper-V, EFLOW and CLI)
    if (!(Test-HyperVStatus -Enable)) { return $false } # todo resume after reboot. Intune will retry. Arc to be checked

    if (!(Test-EadEflowInstall -Install)) { return $false }

    # Check if EFLOW is deployed already and bail out
    if (Test-EadEflowVmDeploy) {
        Write-Host "EFLOW VM is already deployed." -ForegroundColor Yellow
    }
    else {
        if (!(Test-EadEflowVmSwitch -Create)) { return $false } #create switch if specified
        # We are here.. all is good so far. Validate and deploy eflow
        if (!(Invoke-EadEflowDeploy)) { return $false }
    }

    if (! (Test-EadEflowVmProvision)) {
        # Validate and provision eflow
        if (!(Invoke-EadEflowProvision)) { return $false }
    }

    if (! (Test-EadEflowProxyConfiguration)) {
        # Validate and provision eflow
        if (!(Invoke-EadEflowProxyConfiguration)) { return $false }
    }

    if (Verify-EflowVm) {
        $eflowVM = Get-EflowVM
        Write-Host "$($eflowVM.VmConfiguration.name) $($eflowVM.VmPowerState)"
        Write-Host "IoTEdge Info:"
        $eflowVM.EdgeRuntimeVersion | Out-String
        Write-Host "EFLOW VM Info:"
        $eflowVM.SystemStatistics | Out-String
    }

    Enable-Ping
    Update-DockerConfig
    Add-ConfigSettings
    
    return $true
}

# Function to enable ping on the EFLOW VM
function Enable-Ping {
    Write-Host "Enabling ping on EFLOW VM..."
    Invoke-EflowVmCommand "sudo iptables -A INPUT -p icmp --icmp-type 8 -s 0/0 -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT"
    Write-Host "Ping enabled on EFLOW VM."
}

# Function to update the EFLOW VM docker configuration
function Update-DockerConfig {
    try {
        $remoteDaemonJsonPathTemp = "/tmp/daemon.json"
        $remoteDaemonJsonPath = "/etc/docker/daemon.json"

        Write-Host "Update the EFLOW VM docker configuration..."

        # Upload the daemon.json to a temp location on the EFLOW VM
        Write-Host "Uploading daemon.json to EFLOW VM tmp..."
        Copy-EflowVmFile -fromFile (Join-Path $PSScriptRoot "eflow-dockerdaemon.json") -toFile $remoteDaemonJsonPathTemp -pushFile

        # Move it to /etc/docker using sudo
        Write-Host "Moving it /etc/docker..."
        Invoke-EflowVmCommand -Command "sudo mv '$remoteDaemonJsonPathTemp' $remoteDaemonJsonPath"

        # Restart Docker to apply new configuration
        Write-Host "Restarting Docker service to apply changes..."
        Invoke-EflowVmCommand -Command "sudo systemctl restart docker"
    }
    catch {
        Write-Host "Failed to update the EFLOW VM container logging configuration: $($_.Exception.Message)" "ERROR"
    }
}

function Add-ConfigSettings {
    $tomlFile = "/etc/aziot/config.toml"
    $tomlConfigFile = "eflow-config.toml"
    $vmTempFile = "/tmp/eflow-config.toml"  # Temporary file inside EFLOW VM

    try {
        # Copy the TOML config file into the EFLOW VM
        Write-Host "Copying TOML config file to EFLOW VM..."
        Copy-EflowVmFile -fromFile (Join-Path $PSScriptRoot $tomlConfigFile) -toFile $vmTempFile -pushFile

        # Append the config file inside EFLOW VM
        Write-Host "Appending TOML config to $tomlFile inside EFLOW VM..."
        Get-Content (Join-Path $PSScriptRoot $tomlConfigFile) | ForEach-Object {
            Write-Host $_ -ForegroundColor Green
        }

        Invoke-EflowVmCommand -command "sudo bash -c 'cat $vmTempFile >> $tomlFile'"

        Write-Host "TOML config appended successfully."

        # Apply the configuration changes inside EFLOW VM
        Write-Host "Applying configuration to Azure IoT Edge..."
        Invoke-EflowVmCommand -command "sudo iotedge config apply"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Configuration applied successfully."
        }
        else {
            Write-Error "Failed to apply configuration. Exit code: $LASTEXITCODE"
        }

        # Cleanup: Remove the temporary file inside EFLOW VM
        Write-Host "Cleaning up temporary files..."
        Invoke-EflowVmCommand -command "sudo rm -f $vmTempFile"
        Write-Host "Cleanup complete."
    }
    catch {
        Write-Error "Error: $_"
    }
}

### MAIN ###
# Get Host PC information on loading of this script
Get-HostPcInfo

# If autodeploy switch is specified, start eflow deployment with the default json file path (.\eflow-userconfig.json)
if ($AutoDeploy) {
    if (Start-EadWorkflow) {
        Write-Host "Deployment Successful"
    }
    else {
        Write-Error -Message "Deployment failed" -Category OperationStopped
    }
}
else {
    $eflowjson = "$PSScriptRoot\eflow-userconfig.json"
    if (Test-Path -Path "$eflowjson" -PathType Leaf) {
        Set-EadUserConfig $eflowjson
    }
}
