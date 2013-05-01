#AIS SharePoint deployment Scripts for AWS
###############################################################################
# Create Virtual Machine with the given image id, instance type and tag name
# Return the Instance ID of the VM
###############################################################################
workflow CreateVM($AccessKey, $SecretKey, $ImageId, $InstanceType, $KeyName, $MinCount, $MaxCount, $Script, $TagName)
{
	$val = InlineScript
	{
		Add-Type -Path "D:\AWS\References\AWSSDK.dll"
		Add-Type -Path "D:\AWS\References\System.Management.Automation.dll"

	    $client = [Amazon.AWSClientFactory]::CreateAmazonEC2Client($USING:AccessKey, $USING:SecretKey);
	 
	    $runReq = New-Object -TypeName Amazon.EC2.Model.RunInstancesRequest -property @{
	        ImageId=$USING:ImageId; 
	        MaxCount = $USING:MaxCount;
	        MinCount = $USING:MinCount;
	        InstanceType = $USING:InstanceType;
	        KeyName = $USING:KeyName;
	        UserData = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($USING:Script));
	    };
	   
	    $runResp = $client.RunInstances($runReq);

	    $instanceID = $runResp.RunInstancesResult.Reservation.RunningInstance[0].InstanceId;

	    Start-Sleep -Seconds 30;
	    
	    $isTagCreated = "false"

	    while ($isTagCreated -ne "true")
	    {
	        #Creates the tag objects
		    $Tag = New-Object -TypeName Amazon.EC2.Model.Tag -property @{
	                    Key = "Name";
	                    Value = $USING:TagName;
	            };

		    #Prepares the tag request
		    $CreateTagRequest = New-Object -TypeName amazon.EC2.Model.CreateTagsRequest -property @{
	                Tag = @($Tag);
	                ResourceId = @($instanceID);
	            }
		        
		    #Submits the request
		    $tagRequest = $client.CreateTags($CreateTagRequest)	

	        $isTagCreated = "true";
	    }
	    
	    $instanceID;
	}
	
	return $val;
}

###############################################################################
# Get the Public DNS for the given VM with instance id 
# Return the Public DNS of the VM
###############################################################################
workflow GetPublicDNS($AccessKey, $SecretKey, $InstanceID)
{
	$val = InlineScript
	{
		Add-Type -Path "D:\AWS\References\AWSSDK.dll"
		Add-Type -Path "D:\AWS\References\System.Management.Automation.dll"

		$client = [Amazon.AWSClientFactory]::CreateAmazonEC2Client($USING:AccessKey, $USING:SecretKey);
	    $temp = 1;
	    $publicDNS = ""
	    
	    while ($temp -eq 1)
	    {
	        try
	        {
	            $ipReq = New-Object -TypeName Amazon.EC2.Model.DescribeInstancesRequest -property @{
	                InstanceId = @($USING:InstanceID);
	            }

	            $ipResp = $client.DescribeInstances($ipReq);

	            if($ipResp.Length -gt 0)
	            {
	                $publicDNS = $ipResp.DescribeInstancesResult.Reservation[0].RunningInstance[0].PublicDnsName;
	                
	                if($publicDNS.Length -gt 0)
	                {
	                    $temp = 0;
	                }
	            }
	        }
	        catch 
	        { 
				($_.Exception.Message | ConvertFrom-StringData).Save("d:\logs.txt")
	        }
	    }

	    $publicDNS;
	}
	
	return $val;
}

###############################################################################
# Joins a Virtual Machine to the given domain
###############################################################################
workflow JoinDomain($publicDNS, $credentials, $FQDN, $ADIP, $domainName, $InterfaceName, $Password, $UserName)
{
    $isDomainJoined = "false";

    while ($isDomainJoined -ne "true")
    { 
        try
        {
            inlineScript
            {
                netsh interface ip set dns $USING:InterfaceName static $USING:ADIP;

                $pwd = $USING:Password | ConvertTo-SecureString -asPlainText -Force;
                $usernm = "$USING:domainName\$USING:UserName";
                $usernm;
                $credential = New-Object System.Management.Automation.PSCredential($usernm,$pwd);
                Add-Computer -DomainName $USING:FQDN -Credential $credential;

                Restart-Computer -Force;
            } -PSComputerName $publicDNS -PSCredential ($credentials)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

            $isDomainJoined = "true";
        }
        catch
        { 
          #$_.Exception.Message | Out-File "d:\logs.txt" -Append
        }
    }
}

###############################################################################
# Ping the public dns to check if the VM is up and running
###############################################################################
workflow PingServer($PublicDNS)
{
	Add-Type -Path "D:\AWS\References\AWSSDK.dll"
	Add-Type -Path "D:\AWS\References\System.Management.Automation.dll"

    $status = ""
    $count = 0;
    while (($status -ne "Success") -and ($count -le 10))
    { 
        Start-Sleep -Seconds 1;
        $ping = New-Object -TypeName System.Net.NetworkInformation.Ping 
        $reply = $ping.Send($PublicDNS) 
        $status = $reply.Status
        $count++;
    }
   
    return $status;
}

###############################################################################
# Install SharePoint 2013.
###############################################################################
workflow InstallSharePoint($AccessKey, $SecretKey, $InstanceID, $FQDN, $ADIP, $domainName, $SPImg, $Config)
{
	Sequence
    {
		$spsmycreds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @("Administrator",(ConvertTo-SecureString -String "P@ssw0rd" -AsPlainText -Force))
	    
		# Increase C drive space to 100 GB as Default 30 GB space is not enough to install SP 2013.
		inlinescript
		{
			Add-Type -Path "D:\AWS\References\AWSSDK.dll"
			Add-Type -Path "D:\AWS\References\System.Management.Automation.dll"
			
	        $spsClient = [Amazon.AWSClientFactory]::CreateAmazonEC2Client($USING:AccessKey, $USING:SecretKey);
	            
	        $IsExecuted = "false";
	            
	        $count = 0;

	        #Get Volume ID of this instance
	                 
	        "Create Filter"
	        $filter = New-Object -TypeName Amazon.EC2.Model.Filter -property @{
	            withName = "attachment.instance-id";
	            WithValue = $USING:InstanceID;
	        }

	        "Describe Volumes Request"
	        $volumerequest = New-Object -TypeName Amazon.EC2.Model.DescribeVolumesRequest -property @{
	            withfilter = $filter;
	        }

	        "store result and make request"
	        $volumeresult = $spsClient.DescribeVolumes($volumerequest)
	        $volumeID = $volumeresult.DescribeVolumesResult.Volume[0].Attachment[0].VolumeId;
	        $volAZ = $volumeresult.DescribeVolumesResult.Volume[0].AvailabilityZone

	        $createSnapShotRequest = New-Object -TypeName Amazon.EC2.Model.CreateSnapshotRequest -property @{
	            VolumeId = $volumeID;
	            Description = "SP2013SRV-SnapShot";
	        }
	                
	        $createSnapShotResponse = $spsClient.CreateSnapshot($createSnapShotRequest);


	        $snpID = $createSnapShotResponse.CreateSnapshotResult.Snapshot[0].SnapshotId;

	        $isSnpReady = "false"
	                    
	        "Waiting for Snapshot to be completed...."
	                    
	        while($isSnpReady -ne "true")
	        {
	            $desSnpRequest = New-Object -TypeName Amazon.EC2.Model.DescribeSnapshotsRequest -property @{
	                                    SnapshotId = @($snpID);
	                            }

	            $desSnpResponse = $spsClient.DescribeSnapshots($desSnpRequest);

	            $snpStatus = $desSnpResponse.DescribeSnapshotsResult.Snapshot[0].Status

	            if($snpStatus -eq "completed")
	            {
	                $isSnpReady = "true"
	            }
	        }

	        "Snapshot is completed."

	        $NewVolumeID = ""
	                
	        $isVolCreated  = "false";
	        while($isVolCreated -ne "true")
	        {
	            try
	            {
	                $createVolumeRequest = New-Object -TypeName Amazon.EC2.Model.CreateVolumeRequest -property @{
	                    SnapshotId = $snpID;
	                    Size = "100";
	                    VolumeType = "standard";
	                    AvailabilityZone = $volAZ;
	                }

	                $createVolumeResponse = $spsClient.CreateVolume($createVolumeRequest);

	                $NewVolumeID = $createVolumeResponse.CreateVolumeResult.Volume.VolumeId;

	                $isVolCreated = "true";
	            }
	            catch
	            {
	                #$_.Exception.Message | Out-File "d:\logs.txt" -Append
	            }

	        }
	                
	        # Stop the instance to detach the volume.
	        $stoprequest = New-Object -TypeName Amazon.EC2.Model.StopInstancesRequest -property @{
	            InstanceId = $USING:InstanceID;
	        }
	                 
	        $stopResponse = $spsClient.StopInstances($stoprequest)

	        Start-Sleep -Seconds 60;

	        $isDetached ="false";

	        while($isDetached -ne "true")
	        {
	            try
	            {
	                $detachVolumeRequest  = New-Object -TypeName Amazon.EC2.Model.DetachVolumeRequest -property @{
	                    VolumeId = $volumeID;
	                    InstanceId = $USING:InstanceID;
	                    Force = "true";
	                }

	                $detachResponse = $spsClient.DetachVolume($detachVolumeRequest);
	               
	                "Detached Volume $volumeID "
	                        
	                $isDetached = "true";
	            }
	            catch
	            {
	                #$_.Exception.Message | Out-File "d:\logs.txt" -Append
	            } 
	        }
	                
	        Start-Sleep -Seconds 30;

	        $isAttached ="false";

	        while($isAttached -ne "true")
	        {
	            try
	            {
	                $attachVolumeRequest = New-Object -TypeName Amazon.EC2.Model.AttachVolumeRequest -property @{
	                    Device = "/dev/sda1"
	                    InstanceId = $USING:InstanceID;
	                    VolumeId = $NewVolumeID;
	                }
	                

	                $attachResponse = $spsClient.AttachVolume($attachVolumeRequest);
	                
	                "Attached Volume $NewVolumeID";
	                        
	                $isAttached = "true";
	            }
	            catch
	            {
	                #$_.Exception.Message | Out-File "d:\logs.txt" -Append
	            } 
	        }

	        # Start the instance after attaching the volume.
	        $startrequest = New-Object -TypeName Amazon.EC2.Model.StartInstancesRequest -property @{
	            InstanceId = $USING:InstanceID;
	        }
	                 
	        $startResponse = $spsClient.StartInstances($startrequest)
		}
		
		"Waiting for instance to Start..."
        
		Start-Sleep -Seconds 120;
		
		# Public DNS changes when we create a new snapshot and attach it to the instance.
        $NewPublicDNS = GetPublicDNS -AccessKey $AccessKey -SecretKey $SecretKey -InstanceID $InstanceID;
        
        "New Public DNS : $NewPublicDNS ";

        $IsADJoined = "false";
        $GetSPImage = "false"
        $InstallRF1  = "false";
        $InstallRF2  = "false";
        $DownloadPR = "false";
        $InstallPR1 = "false";
        $InstallPR2 = "false";
        $InstallSP1 = "false";
        $InstallSP2 = "false";
        $isDiskExpanded = "false";
        $IsSSPIEnabled = "false";
        $IsUserAdded = "false";

        while ($IsExecuted -ne "true")
        { 
            try
            {
                 # Enable SSP
                if($IsSSPIEnabled -ne "true")
                {
                    inlineScript
                    {
                        Enable-WSManCredSSP –Role Server -Force
                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    "SSPI enabled";

                    $IsSSPIEnabled = "true";
                }

                # Join This Machine to Domain
                if($IsADJoined -ne "true")
                {
                    
                    JoinDomain -publicDNS $NewPublicDNS -credentials $spsmycreds -FQDN $FQDN -ADIP $ADIP -domainName $domainName -InterfaceName "Ethernet" -Password "P@ssw0rd" -UserName "Administrator";

                   
                    "PingServer -PublicDNS $NewPublicDNS";
                    
                    PingServer -PublicDNS $NewPublicDNS;
                    
                    "Restarted After Joining to Domain";
                    
                    $IsADJoined = "true";
                }

                if($isDiskExpanded -ne "true")
                {
                    inlineScript
                    {
                        $a = "select disk 0","select volume 1","extend" | diskpart
                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)
                
                    "Disk Expanded !";
                    $isDiskExpanded = "true"
                }

                # Download Image File
                if($GetSPImage -ne "true")
                {
                    inlineScript
                    {
                        function dostuff($tolocation, $fromlocation)
                        {
                            if(Test-Path $tolocation)
                            {} else
                            {
                                md $tolocation
                            }
                            if(Test-Path $fromlocation){
                                testandmove $tolocation $fromlocation
                            }
                            else{
                                "$fromlocation was not found."
                            }
                        }

                        function testandmove($thepitfolder, $specialdrive)
                        {
	                        $ultraarray = Get-ChildItem $specialdrive\* -Recurse
	                        foreach($superitem in $ultraarray){
	                            $tempstring = $superitem.FullName.substring($specialdrive.Length)
	                            if(Test-Path $thepitfolder\$tempstring){
	                                "$thepitfolder\$tempstring already exists."
	                            }
	                            else{
	                                copy-item $superitem.FullName $thepitfolder\$tempstring
	                            }
	        
	                        }
                    	}

	                    "Downloading SP 2013 Image..."
	                    $packagesource = $USING:SPImg;
	                    $ImagePath = "C:\sp2013.img"
	                    $wc = New-Object System.Net.WebClient
	                    $wc.DownloadFile($packagesource, $ImagePath) 

	                    "SP 2013 image downloaded."

	                    "Mounting Disk.."
	                    Mount-DiskImage -ImagePath $ImagePath
	                    $ISODrive = (Get-DiskImage -ImagePath $ImagePath | Get-Volume).DriveLetter

	                    "Mounted to Drive $ISODrive"
	                    #append colon to drive letter
	                    $from = $ISODrive+ ":\"

	                    #create directory
	                    new-item -Path "c:\sp2013" -ItemType directory
	                    $to= "c:\sp2013"

	                    #copy files into new folder 
	                    dostuff "C:\SP2013"  $from
	                    Dismount-DiskImage -ImagePath $ImagePath

	                    # Download the Config.xml to c:\SP2013 folder.
	                                
	                    $wc1 = New-Object System.Net.WebClient;
	                    $wc1.DownloadFile("$USING:Config", $to + "\config.xml")

                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    $GetSPImage = "true";
                }

                # Join This Machine to Domain
                if($IsUserAdded -ne "true")
                {
                    inlineScript
                    {
                        set-content "c:\addUser.ps1" "`$group = [ADSI]('WinNT://'+`$env:COMPUTERNAME+'/administrators,group'); `$group.add('WinNT://corp/SPFarm')";
                        c:\addUser.ps1;
                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    "SP Farm user added to Admin Group";
                    $IsUserAdded = "true";
                }

                # Install SP2013 Roles and Features
                if($InstallRF1 -ne "true")
                {
                    inlineScript
                    {
                        Import-Module ServerManager

                        function AddWindowsFeatures() 
                        { 
                            # Note: You can use the Get-WindowsFeature cmdlet (its in the ServerManager module) to get a listing of all features and roles.
                            $WindowsFeatures = @(
			                    "Net-Framework-Features",
			                    "Web-Server",
			                    "Web-WebServer",
			                    "Web-Common-Http",
			                    "Web-Static-Content",
			                    "Web-Default-Doc",
			                    "Web-Dir-Browsing",
			                    "Web-Http-Errors",
			                    "Web-App-Dev",
			                    "Web-Asp-Net",
			                    "Web-Net-Ext",
			                    "Web-ISAPI-Ext",
			                    "Web-ISAPI-Filter",
			                    "Web-Health",
			                    "Web-Http-Logging",
			                    "Web-Log-Libraries",
			                    "Web-Request-Monitor",
			                    "Web-Http-Tracing",
			                    "Web-Security",
			                    "Web-Basic-Auth",
			                    "Web-Windows-Auth",
			                    "Web-Filtering",
			                    "Web-Digest-Auth",
			                    "Web-Performance",
			                    "Web-Stat-Compression",
			                    "Web-Dyn-Compression",
			                    "Web-Mgmt-Tools",
			                    "Web-Mgmt-Console",
			                    "Web-Mgmt-Compat",
			                    "Web-Metabase",
			                    "Application-Server",
			                    "AS-Web-Support",
			                    "AS-TCP-Port-Sharing",
			                    "AS-WAS-Support",
			                    "AS-HTTP-Activation",
			                    "AS-TCP-Activation",
			                    "AS-Named-Pipes",
			                    "AS-Net-Framework",
			                    "WAS",
			                    "WAS-Process-Model",
			                    "WAS-NET-Environment",
			                    "WAS-Config-APIs",
			                    "Web-Lgcy-Scripting",
			                    "Windows-Identity-Foundation",
			                    "Server-Media-Foundation",
			                    "Xps-Viewer")
    
                        $source = "" 

                        $myCommand = 'Add-WindowsFeature ' + [string]::join(",",$WindowsFeatures) + $source

	                    # Execute $myCommand
                        $operation = Invoke-Expression $myCommand  
                    } 

                    AddWindowsFeatures
 
                    Restart-Computer -Force;

                } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    $InstallRF1 = "true";
                }

                PingServer -PublicDNS $NewPublicDNS;

                "Restarted After Installing Roles and Features";

                # Install SP2013 Roles and Features After Restart
                if($InstallRF2 -ne "true")
                {
                    inlineScript
                    {
                        Import-Module ServerManager

                        function AddWindowsFeatures() 
                        { 
                            # Note: You can use the Get-WindowsFeature cmdlet (its in the ServerManager module) to get a listing of all features and roles.
                                                                                                                                                                                                                    $WindowsFeatures = @(
			                    "Net-Framework-Features",
			                    "Web-Server",
			                    "Web-WebServer",
			                    "Web-Common-Http",
			                    "Web-Static-Content",
			                    "Web-Default-Doc",
			                    "Web-Dir-Browsing",
			                    "Web-Http-Errors",
			                    "Web-App-Dev",
			                    "Web-Asp-Net",
			                    "Web-Net-Ext",
			                    "Web-ISAPI-Ext",
			                    "Web-ISAPI-Filter",
			                    "Web-Health",
			                    "Web-Http-Logging",
			                    "Web-Log-Libraries",
			                    "Web-Request-Monitor",
			                    "Web-Http-Tracing",
			                    "Web-Security",
			                    "Web-Basic-Auth",
			                    "Web-Windows-Auth",
			                    "Web-Filtering",
			                    "Web-Digest-Auth",
			                    "Web-Performance",
			                    "Web-Stat-Compression",
			                    "Web-Dyn-Compression",
			                    "Web-Mgmt-Tools",
			                    "Web-Mgmt-Console",
			                    "Web-Mgmt-Compat",
			                    "Web-Metabase",
			                    "Application-Server",
			                    "AS-Web-Support",
			                    "AS-TCP-Port-Sharing",
			                    "AS-WAS-Support",
			                    "AS-HTTP-Activation",
			                    "AS-TCP-Activation",
			                    "AS-Named-Pipes",
			                    "AS-Net-Framework",
			                    "WAS",
			                    "WAS-Process-Model",
			                    "WAS-NET-Environment",
			                    "WAS-Config-APIs",
			                    "Web-Lgcy-Scripting",
			                    "Windows-Identity-Foundation",
			                    "Server-Media-Foundation",
			                    "Xps-Viewer" )
                            $source = "" 

                            $myCommand = 'Add-WindowsFeature ' + [string]::join(",",$WindowsFeatures) + $source

	                        # Execute $myCommand
                            $operation = Invoke-Expression $myCommand  
                        } 

                        AddWindowsFeatures
 
                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    $InstallRF2 = "true";
                }

                PingServer -PublicDNS $NewPublicDNS;

                "Restarted After Installing Roles and Features Again.";

                # Install SP2013 Pre-Requisite Files 
                if($InstallPR1 -ne "true")
                {
                    inlineScript
                    {
                    $SharePoint2013Path = "C:\SP2013";
 
                    function InstallPreReqFiles() 
                    { 

                        $ReturnCode = 0

                        Try 
                        { 
                            Start-Process "$SharePoint2013Path\PrerequisiteInstaller.exe" -ArgumentList "  /unattended "  -WindowStyle Minimized -Wait
                        } 
                        Catch 
                        { 
                            $ReturnCode = -1 
                                $_ 
                            break 
                        }     
 
                        return $ReturnCode 
                    } 
 
                    function CheckProvidedSharePoint2013Path()
                    {
                        $ReturnCode = 0

                        Try 
                        { 
                            # Check if destination path exists 
                            If (Test-Path $SharePoint2013Path) 
                            { 
                                # Remove trailing slash if it is present
                                $script:SharePoint2013Path = $SharePoint2013Path.TrimEnd('\')
	                            $ReturnCode = 0
                            }
                            Else
                            {

	                            $ReturnCode = -1
                                ""
	                            "Your specified download path does not exist. Please verify your download path then run this script again."
                                ""
                            } 
                        } 
                        Catch 
                        { 
                            $ReturnCode = -1 
                            "An error has occurred when checking your specified download path" 
                            $_ 
                            break 
                        }     
    
                        return $ReturnCode 
                    }
 
                    function InstallPreReqs() 
                    { 
                        $rc = 0 
                        $rc = CheckProvidedSharePoint2013Path  
     
                        # Install the Pre-Reqs 
                        if($rc -ne -1) 
                        { 
                            $rc = InstallPreReqFiles 
                        } 

                        if($rc -ne -1)
                        {

                            ""
                            "Script execution is now complete!"
                            ""
                        }
                    } 

                    InstallPreReqs
                            
                    Restart-Computer -Force;

                } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    $InstallPR1 = "true";
                }

                PingServer -PublicDNS $NewPublicDNS;

                "Restarted After Installing SP 2013 Pre-Requisites";

                # Install SP2013 Pre-Requisite Files After Restart
                if($InstallPR2 -ne "true")
                {
                    inlineScript
                    {
                        $SharePoint2013Path = "C:\SP2013";
 
                        function InstallPreReqFiles() 
                        { 

                            $ReturnCode = 0

                            ""
                            "====================================================================="
                            "Installing Prerequisites required for SharePoint 2013" 
                            ""
                            "This uses the supported installing offline method"
                            ""
                            "If you have not installed the necessary Roles/Features"
                            "this will occur at this time."
                            "=====================================================================" 
                                
                            Try 
                            { 
                                Start-Process "$SharePoint2013Path\PrerequisiteInstaller.exe" -ArgumentList "  /unattended "  -WindowStyle Minimized -Wait
                            } 
                            Catch 
                            { 
                                $ReturnCode = -1 
                                $_ 
                                break 
                            }     
 
                            return $ReturnCode 
                        } 
 
                        function CheckProvidedSharePoint2013Path()
                        {
                            $ReturnCode = 0

                            Try 
                            { 
                                # Check if destination path exists 
                                If (Test-Path $SharePoint2013Path) 
                                { 
                                    # Remove trailing slash if it is present
                                    $script:SharePoint2013Path = $SharePoint2013Path.TrimEnd('\')
	                                $ReturnCode = 0
                                }
                                Else
                                {

	                                $ReturnCode = -1
                                    ""
	                                "Your specified download path does not exist. Please verify your download path then run this script again."
                                    ""
                                } 
                            } 
                            Catch 
                            { 
                                $ReturnCode = -1 
                                "An error has occurred when checking your specified download path" 
                                $_ 
                                break 
                            }     
    
                            return $ReturnCode 
                        }
 
                        function InstallPreReqs() 
                        { 
                            $rc = 0 
                            $rc = CheckProvidedSharePoint2013Path  
     
                            # Install the Pre-Reqs 
                            if($rc -ne -1) 
                            { 
                                $rc = InstallPreReqFiles 
                            } 

                            if($rc -ne -1)
                            {

                                ""
                                "Script execution is now complete!"
                                ""
                            }
                        } 

                        InstallPreReqs
                            
                        Restart-Computer -Force;

                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    $InstallPR2 = "true";
                }

                PingServer -PublicDNS $NewPublicDNS;

                "Restarted After Installing SP 2013 Pre-Requisites Again.";

                # Install SharePoint
                if($InstallSP1 -ne "true")
                {
                    inlineScript
                    {
                        $SharePoint2013Path = "C:\SP2013";

                        function InstallPreReqFiles() 
                        { 
                            $ReturnCode = 0
                            ""
                            "====================================================================="
                            "Installing SharePoint 2013" 
                            ""
                            "=====================================================================" 
                            Try 
                            { 
                                Start-Process "$SharePoint2013Path\Setup.exe" -ArgumentList "/config $SharePoint2013Path\config.xml" -Wait
                            } 
                            Catch  
                            { 
                                $ReturnCode = -1 
                                $_ 
                                break 
                            }     
 
                            return $ReturnCode 
                        } 
 
                        function CheckProvidedSharePoint2013Path()
                        {
                            $ReturnCode = 0

                            Try 
                            { 
                                # Check if destination path exists 
                                If (Test-Path $SharePoint2013Path) 
                                { 
                                    # Remove trailing slash if it is present
                                    $script:SharePoint2013Path = $SharePoint2013Path.TrimEnd('\')
	                                $ReturnCode = 0
                                }
                                Else 
                                {
	                                $ReturnCode = -1
                                    ""
	                                "Your specified download path does not exist. Please verify your download path then run this script again."
                                    ""
                                } 
                            } 
                            Catch 
                            { 
                                    $ReturnCode = -1 
                                    "An error has occurred when checking your specified download path" 
                                    $_ 
                                    break 
                            }     
    
                            return $ReturnCode 
                        }
 
                        function InstallPreReqs() 
                        { 
                            $rc = 0 
                            $rc = CheckProvidedSharePoint2013Path  
     
                            # Install the Pre-Reqs 
                            if($rc -ne -1) 
                            { 
                                $rc = InstallPreReqFiles 
                            } 

                            if($rc -ne -1)
                            {
                                ""
                                "Script execution is now complete!"
                                ""
                            }
                        }

                        #Download the Config.xml to c:\SP2013 folder.
                        $wc1 = New-Object System.Net.WebClient;
                        $wc1.DownloadFile("$USING:Config", "C:\SP2013\config.xml");

                        InstallPreReqs

                        Restart-Computer -Force;

                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    $InstallSP1 = "true";
                }

                PingServer -PublicDNS $NewPublicDNS;

                "Restarted After Installing SP 2013.";

                # Install SharePoint
                if($InstallSP2 -ne "true")
                {
                    inlineScript
                    {
                        $SharePoint2013Path = "C:\SP2013";
 
                        function InstallPreReqFiles() 
                        { 
                            $ReturnCode = 0
                            ""
                            "====================================================================="
                            "Installing SharePoint 2013" 
                            ""
                            "=====================================================================" 
                            Try 
                            { 
                                Start-Process "$SharePoint2013Path\Setup.exe" -ArgumentList "/config $SharePoint2013Path\config.xml" -Wait
                            } 
                            Catch  
                            { 
                                $ReturnCode = -1 
                                $_ 
                                break 
                            }     
 
                            return $ReturnCode 
                        } 
 
                        function CheckProvidedSharePoint2013Path()
                        {
                            $ReturnCode = 0

                            Try 
                            { 
                                # Check if destination path exists 
                                If (Test-Path $SharePoint2013Path) 
                                { 
                                    # Remove trailing slash if it is present
                                    $script:SharePoint2013Path = $SharePoint2013Path.TrimEnd('\')
	                                $ReturnCode = 0
                                }
                                Else 
                                {
	                                $ReturnCode = -1
                                    ""
	                                "Your specified download path does not exist. Please verify your download path then run this script again."
                                    ""
                                } 
                            } 
                            Catch 
                            { 
                                    $ReturnCode = -1 
                                    "An error has occurred when checking your specified download path" 
                                    $_ 
                                    break 
                            }     
    
                            return $ReturnCode 
                        }
 
                        function InstallPreReqs() 
                        { 
                            $rc = 0 
                            $rc = CheckProvidedSharePoint2013Path  
     
                            # Install the Pre-Reqs 
                            if($rc -ne -1) 
                            { 
                                $rc = InstallPreReqFiles 
                            } 

                            if($rc -ne -1)
                            {
                                ""
                                "Script execution is now complete!"
                                ""
                            }
                        }

                        InstallPreReqs

                        Restart-Computer -Force;

                    } -PSComputerName $NewPublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                    $InstallSP2 = "true";
                }

                PingServer -PublicDNS $NewPublicDNS;

                "SP 2013 Server is Ready to Use";

                $IsExecuted = "true";
            }
            catch
            {
				#$_.Exception.Message | Out-File "d:\logs.txt" -Append
               	$Count = $Count + 1;
               	"Trying " + $Count + " time";
			   	Start-Sleep -Seconds 30;
            }
        }

        "=========================SP END========================="
    }
}

###############################################################################
# Ping the of list of servers public dns to check if the VMs are up and running
###############################################################################
workflow CheckServers([string[]] $servers)
{
	foreach($server in $servers)
    {
        inlinescript
		{
			Add-Type -Path "D:\AWS\References\AWSSDK.dll"
			Add-Type -Path "D:\AWS\References\System.Management.Automation.dll"
		    $status = ""
		    $count = 0;
		    while (($status -ne "Success") -and ($count -le 10))
		    { 
		        Start-Sleep -Seconds 5;
		        $ping = New-Object -TypeName System.Net.NetworkInformation.Ping 
		        $reply = $ping.Send($USING:server) 
		        $status = $reply.Status
		        $count++;
		    }
		   
			if($status -ne "Success")
	        {
	            return "false";
	        }
		}
    }
	
	return "true";
}

###############################################################################
# Main Workflow to Deploy SP 2013 Farm
###############################################################################
workflow AWS-SP-Farm($AccessKey, $SecretKey, $keyName)
{
    #Variable Decleration
	
	#Paths [Please Modify Before Execution, Please use short/tiny urls]
	$StartUpScriptPath = "[Your StartUp.ps1 path]"
	$ADDForestPath = "[Your ADDForest.ps1 path]"
    $SP2013ImagePath = "[Your SP2013 image path]"
	$ConfigFilePath = "[Your Config.xml path]"
	
    #common
    $AdminPassword = "P@ssw0rd";
    $maxCount = 1;
    $minCount = 1;
   
    #Active Directory
    $ADImageId = "ami-2c82e345"; # Windows Server 2012 Base
    $ADInstanceType = "m1.medium";
    $FQDN ="corp.ais.com" #Your Fully Qualifided Domain Name
    $domainName = "corp"; 
    $NetBIOSName = "corp"; #Domain Controller Net Bios Name
    $SafeModePassword = "Ais@12345"; #Domain Controller Safe Mode Recovery Password
    $ADIP = ""; # Active Directory IP Address (Leave Blank)

    #SQL Server
    $SQLImageId = "ami-2882e341"; #Windows Server 2012 with SQL Server Standard
    $SQLInstanceType="m1.medium";
    $SQLVMName = "";

    #Sharepoint
    $SPInstanceType = "m1.medium";
    $sp1VMName = "";
    
    $ADInstanceID =""
    $SQLInstanceID =""
    $SP1InstanceID =""
    $SP2InstanceID =""
    
    $ADPublicDNS =""
    $SQLPublicDNS =""
    $SP1PublicDNS =""
    $SP2PublicDNS =""
	
    $script = "`$wc = new-object system.net.webclient; `$wc.DownloadFile('$StartUpScriptPath','StartUp.ps1')";
    $userData =  "<powershell> Set-ExecutionPolicy UnRestricted -Force; $script ; .\StartUp.ps1 ;  </powershell>" ;
    
    # SP Farm
    sequence 
    {
        # Create VMs
        
        "Started Creating VMs"

        sequence
        { 
            $WORKFLOW:ADInstanceID  =  CreateVM -AccessKey $AccessKey -SecretKey $SecretKey `
                                                -ImageId $ADImageId -InstanceType $ADInstanceType `
                                                -KeyName $keyName -MinCount $minCount `
                                                -MaxCount $maxCount -Script $userData `
                                                -TagName "DomainController"

            $WORKFLOW:ADPublicDNS   =  GetPublicDNS -AccessKey $AccessKey -SecretKey $SecretKey -InstanceID $ADInstanceID;

            "Domain Controller : $WORKFLOW:ADPublicDNS";
        }

        sequence
        {
            $WORKFLOW:SQLInstanceID =  CreateVM -AccessKey $AccessKey -SecretKey $SecretKey `
                                                -ImageId $SQLImageId -InstanceType $SQLInstanceType `
                                                -KeyName $keyName -MinCount $minCount `
                                                -MaxCount $maxCount -Script $userData `
                                                -TagName "SQLServer";

            $WORKFLOW:SQLPublicDNS  =  GetPublicDNS -AccessKey $AccessKey -SecretKey $SecretKey -InstanceID $SQLInstanceID;

            "SQL Server : $WORKFLOW:SQLPublicDNS";
        }

        sequence
        {
            $WORKFLOW:SP1InstanceID =  CreateVM -AccessKey $AccessKey -SecretKey $SecretKey `
                                                -ImageId $ADImageId -InstanceType $SPInstanceType `
                                                -KeyName $keyName -MinCount $minCount `
                                                -MaxCount $maxCount -Script $userData `
                                                -TagName "SP2013SRV1";

            $WORKFLOW:SP1PublicDNS  =  GetPublicDNS -AccessKey $AccessKey -SecretKey $SecretKey -InstanceID $SP1InstanceID;

            "SharePoint Server 1 : $WORKFLOW:SP1PublicDNS";

        }

        sequence
        {
            $WORKFLOW:SP2InstanceID =  CreateVM -AccessKey $AccessKey -SecretKey $SecretKey `
                                                -ImageId $ADImageId -InstanceType $SPInstanceType `
                                                -KeyName $keyName -MinCount $minCount `
                                                -MaxCount $maxCount -Script $userData `
                                                -TagName "SP2013SRV2";
                
            $WORKFLOW:SP2PublicDNS  =  GetPublicDNS -AccessKey $AccessKey -SecretKey $SecretKey -InstanceID $SP2InstanceID;

            "SharePoint Server 2 : $WORKFLOW:SP2PublicDNS";

        }
        
		Start-Sleep -Seconds 300; #wait until the VMs are Provisioned.
		
        $servers = @($ADPublicDNS,$SQLPublicDNS,$SP1PublicDNS,$SP2PublicDNS);

		$result = CheckServers -servers $servers
		
        if($result -ne "true")
        {
            " Trouble accessing one or more VMs";
        }

        "Completed Creating VMs"

        Checkpoint-Workflow;
        
        "Waiting for the VMs to boot up..."
        
        Start-Sleep -Seconds 60;

        # Domain Controller
        sequence 
        {
            "=========================AD Domain Controller Start=========================" 
           
            $publicDNS = $ADPublicDNS;

            "AD Domain Controller instance Public DNS: $publicDNS";
            
            PingServer -PublicDNS $ADPublicDNS;
            
            "AD Domain Controller is ready to use.";

            $WORKFLOW:ADIP = inlineScript
            {
                $a = ($USING:publicDNS) -match  "ec2-(?<content>.*).compute*";
                $Matches['content'].Replace('-', '.') ;
            }

            "AD Domain Controller IP Address : $ADIP";
             
            $mycreds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @("Administrator",(ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force))
            
            $IsExecuted = "false";
            
            $count = 0;
            $IsADCreated = "false";
            $IsADDSForestCreated = "false";
            $UsersAlreadyCreated = "false";

            while ($IsExecuted -ne "true")
            { 
                Start-Sleep -Seconds 30;

                try
                {
                    if($IsADCreated -ne "true")
                    {
                        inlineScript
                        {
                            $addsTools = "RSAT-AD-Tools"
                            Add-WindowsFeature $addsTools
                            start-job -Name addFeature -ScriptBlock { 
                            Add-WindowsFeature -Name "ad-domain-services" -IncludeAllSubFeature -IncludeManagementTools 
                            Add-WindowsFeature -Name "dns" -IncludeAllSubFeature -IncludeManagementTools 
                            Add-WindowsFeature -Name "gpmc" -IncludeAllSubFeature -IncludeManagementTools } 
                            Wait-Job -Name addFeature 
                            Restart-Computer;
                        } -PSComputerName $publicDNS -PSCredential ($mycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                        $IsADCreated = "true";
						
						"PingServer -PublicDNS $publicDNS;"
                    	PingServer -PublicDNS $publicDNS;
                    
                    	"Restarted After ADD AD Feature !!";
                    }

                    if($IsADDSForestCreated -ne "true")
                    {
                        inlineScript
                        {                      
                            $wc = New-Object System.Net.WebClient; 
                            $wc.DownloadFile('$USING:ADDForestPath','C:\ADDSForest.ps1');
                            $domainName = $USING:FQDN;
                            $BiosName = $USING:NetBIOSName;
                            $SafePassword = $USING:SafeModePassword;
                            cd \;
                            .\ADDSForest.ps1 -domainname $domainName -netbiosName $BiosName -safeModePassword $SafePassword;
                        } -PSComputerName $publicDNS -PSCredential ($mycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                        $IsADDSForestCreated = "true";
						
						"PingServer -PublicDNS $publicDNS;"
                    	PingServer -PublicDNS $publicDNS;
                    
                    	"Restarted After ADDS Forest !!";
                    }

                    # Create AD Service Accounts and Users
                    if($UsersAlreadyCreated -ne "true")
                    {
                        InlineScript
                        {
                            Import-Module ActiveDirectory  
                            function createUser 
                            {    
                                    param ([string] $ou, [string] $firstName, [string] $lastName, [string] $password, [string] $emailDomain)     
                                    $userName = $firstName + "." + $lastName    
                                    $fullName = $firstName + " " + $lastName   
                                    $emailAddress = $username + "@" + $emailDomain   
                                    New-ADUser -SamAccountName $userName -Name $fullName -DisplayName $fullName -GivenName $firstName -Surname $lastName -Path $ou -ChangePasswordAtLogon $false -AccountPassword (ConvertTo-SecureString -AsPlainText -String $password -Force) -Description $fullName -Enabled $true -EmailAddress $emailAddress -PasswordNeverExpires $true -UserPrincipalName $emailAddress 
                            }  
                            function createServiceUser 
                            {  
                                    param ([string] $ou, [string] $userName, [string] $password, [string] $emailDomain)     
                                    $emailAddress = $username + "@" + $emailDomain     
                                    New-ADUser -SamAccountName $userName -Name $userName -DisplayName $fullName -Path $ou -ChangePasswordAtLogon $false -AccountPassword (ConvertTo-SecureString -AsPlainText -String $password -Force) -Description $userName -Enabled $true -EmailAddress $emailAddress -PasswordNeverExpires $true -UserPrincipalName $emailAddres
                            }  

                            $domain = [ADSI] "LDAP://dc=corp, dc=ais,dc=com"  
                            $ouServices = $domain.Create("OrganizationalUnit", "OU=Services")
                            $ouServices.SetInfo()  
                            $ouUserProfiles = $domain.Create("organizationalUnit", "ou=SharePoint Users") 
                            $ouUserProfiles.SetInfo()  
 
                            $ouUserProfilesEmployees = $ouUserProfiles.Create("organizationalUnit", "ou=Employees")
                            $ouUserProfilesEmployees.SetInfo()  
                            $services = [ADSI] "LDAP://ou=Services,dc=corp,dc=ais,dc=com"
                            $employees = [ADSI] "LDAP://ou=Employees,ou=SharePoint Users,dc=corp,dc=ais,dc=com"  
                            $fakePassword = "Passw0rd" 
                            $emailDomain = "corp.ais.com"  
                            createServiceUser -ou $services.distinguishedName -userName "SPFarm" -password $fakePassword - emailDomain $emailDomain
                            createServiceUser -ou $services.distinguishedName -userName "SPService" -password $fakePassword - emailDomain $emailDomain
                            createServiceUser -ou $services.distinguishedName -userName "SPContent" -password $fakePassword - emailDomain $emailDomain
                            createServiceUser -ou $services.distinguishedName -userName "SPSearch" -password $fakePassword - emailDomain $emailDomain 
                            createServiceUser -ou $services.distinguishedName -userName "SPUPS" -password $fakePassword - emailDomain $emailDomain 
                            createServiceUser -ou $services.distinguishedName -userName "SQLService" -password $fakePassword - emailDomain $emailDomain
                            createServiceUser -ou $services.distinguishedName -userName "SQLAgent" -password $fakePassword - emailDomain $emailDomain
                            createServiceUser -ou $services.distinguishedName -userName "SQLReporting" -password $fakePassword -emailDomain $emailDomain  
                            $c = 1   
                            do 
                            {    
                                    $firstName = "fn" + $c  
                                    $lastName = "ln" + $c   
                                    createUser -ou $employees.distinguishedName -firstName $firstName -lastName $lastName -password $fakePassword -emailDomain $emailDomain  
                                    $c++
                            } while ($c -le 500)

                        } -PSComputerName $publicDNS -PSCredential ($mycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                        $UsersAlreadyCreated = "true";
						
						"Created AD Service Accounts and Users";
                    	$IsExecuted = "true";
                    }
                }
                catch
                {
					#$_.Exception.Message | Out-File "d:\logs.txt" -Append
                    $Count = $Count + 1;
                    "Trying " + $Count + " time";
                }
            }

            "=========================AD Domain Controller END========================="
        }

        Start-Sleep -Seconds 120;

        # Domain Members
        parallel
        {
            # SQL Server
            sequence
            {
                "=========================SQL Server Start=========================" 

                "SQL Server VM Public DNS: $SQLPublicDNS";
          
                PingServer -PublicDNS $SQLPublicDNS;
            
                "SQL Server is ready to use."
              
                $sqlmycreds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @("Administrator",(ConvertTo-SecureString -String "P@ssw0rd" -AsPlainText -Force))
            
                $IsExecuted = "false";
            
                $count = 0;
                $IsADJoined = "false";
                $ServiceAccountsChanged = "false";
                $IsUserAdded = "false";

                while ($IsExecuted -ne "true")
                { 
                    try
                    {
                            $WORKFLOW:SQLVMName = inlineScript
                            {
                                Get-Content env:computername;
                            } -PSComputerName $SQLPublicDNS -PSCredential ($sqlmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)
                    
                            inlineScript
                            {
                                netsh advfirewall firewall add rule name="Port 1433" dir=in action=allow protocol=TCP localport=1433
                            } -PSComputerName $sqlPublicDNS -PSCredential ($sqlmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                            if($IsADJoined -ne "true")
                            {
                        
                                JoinDomain -publicDNS $SQLPublicDNS -credentials $sqlmycreds -FQDN $FQDN -ADIP $ADIP -domainName $NetBIOSName -InterfaceName "Ethernet" -Password "P@ssw0rd" -UserName "Administrator";
                            
                                "SQL Server VM Name : $SQLVMName";
                            
                                $IsADJoined = "true";
                            }

                            PingServer -PublicDNS $SQLPublicDNS;
                       
                     
                            if($ServiceAccountsChanged -ne "true")
                            {
                                inlineScript
                                {
                                    # configure SQL Server 2012 services (engine, agent, reporting) in order to use these domain accounts

                                    $account1="corp\SQLService"
                                    $password1="Passw0rd"
                                    $service1="name='MSSQLSERVER'"

                                    $svc1=gwmi win32_service -filter $service1
                                    $svc1.StopService()
                                    $svc1.change($null,$null,$null,$null,$null,$null,$account1,$password1,$null,$null,$null)
                                    $svc1.StartService()

                                    $account2="corp\SQLAgent"
                                    $password2="Passw0rd"
                                    $service2="name='SQLSERVERAGENT'"
                            
                                    $svc2=gwmi win32_service -filter $service2
                                    $svc2.StopService()
                                    $svc2.change($null,$null,$null,$null,$null,$null,$account2,$password2,$null,$null,$null)
                                    $svc2.StartService()

                                    $account3="corp\SQLReporting"
                                    $password3="Passw0rd"
                                    $service3="name='ReportServer'"
                            
                                    $svc3=gwmi win32_service -filter $service3
                                    $svc3.StopService()
                                    $svc3.change($null,$null,$null,$null,$null,$null,$account3,$password3,$null,$null,$null)
                                    $svc3.StartService()

                                    # configure the SPFarm account in roles securityadmin and dbcreator onto the SQL Server engine

                                    Invoke-Sqlcmd -ServerInstance . -Database master –Query `
                                    "USE [master]
                                    GO
                                    CREATE LOGIN [corp\SPFarm] FROM WINDOWS WITH DEFAULT_DATABASE=[master]
                                    GO
                                    ALTER SERVER ROLE [dbcreator] ADD MEMBER [corp\SPFarm]
                                    GO
                                    ALTER SERVER ROLE [securityadmin] ADD MEMBER [corp\SPFarm]
                                    GO"

                                    Invoke-Sqlcmd -ServerInstance . –Query `
                                    "sp_configure 'show advanced options', 1;
                                    GO
                                    RECONFIGURE WITH OVERRIDE;
                                    GO
                                    sp_configure 'max degree of parallelism', 1;
                                    GO
                                    RECONFIGURE WITH OVERRIDE;
                                    GO"
                                } -PSComputerName $sqlPublicDNS -PSCredential ($sqlmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)

                                $ServiceAccountsChanged = "true";

                                "Changed The Service Accounts in SQL Server Machine";
                            }

                            if($IsUserAdded -ne "true")
                            {
                                inlineScript
                                {
                                    set-content "c:\addUser.ps1" "`$group = [ADSI]('WinNT://'+`$env:COMPUTERNAME+'/administrators,group'); `$group.add('WinNT://corp/SPFarm')";
                                    c:\addUser.ps1;
                                } -PSComputerName $SQLPublicDNS -PSCredential ($sqlmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck)
                                
                                "Added User SPFarm to Server";

                                $IsUserAdded = "true";
                            }

                            $IsExecuted = "true";
                    }
                    catch
                    {
						#$_.Exception.Message | Out-File "d:\logs.txt" -Append
                        $Count = $Count + 1;
                        "Trying " + $Count + " time";
						Start-Sleep -Seconds 10;
                    }
                }

                "=========================SQL Server END=========================="
            }

            # SharePoint Server 1
            sequence
            {
                "InstallSharePoint -AccessKey $AccessKey  -SecretKey $SecretKey `
                -InstanceID $SP1InstanceID -FQDN $FQDN -ADIP $ADIP -domainName $NetBIOSName `
				-SPImg $SP2013ImagePath -Config $ConfigFilePath"
        
                InstallSharePoint -AccessKey $AccessKey  -SecretKey $SecretKey `
				-InstanceID $SP1InstanceID -FQDN $FQDN -ADIP $ADIP -domainName $NetBIOSName `
				-SPImg $SP2013ImagePath -Config $ConfigFilePath;
            }

            # SharePoint Server 2
            sequence
            {
                "InstallSharePoint -AccessKey $AccessKey  -SecretKey $SecretKey `
                -InstanceID $SP2InstanceID -FQDN $FQDN -ADIP $ADIP -domainName $NetBIOSName `
				-SPImg $SP2013ImagePath -Config $ConfigFilePath"
        
                InstallSharePoint -AccessKey $AccessKey  -SecretKey $SecretKey `
				-InstanceID $SP2InstanceID -FQDN $FQDN -ADIP $ADIP -domainName $NetBIOSName `
				-SPImg $SP2013ImagePath -Config $ConfigFilePath;
            }
        }

        Checkpoint-Workflow;

        # Configure SP Farm
        sequence
        {
            "=========================Configure SP Farm Start============================="
            
            "check if SP2013SRV1 is available"
            
            $WORKFLOW:SP1PublicDNS  =  GetPublicDNS -AccessKey $AccessKey -SecretKey $SecretKey -InstanceID $SP1InstanceID;
            $WORKFLOW:SP2PublicDNS  =  GetPublicDNS -AccessKey $AccessKey -SecretKey $SecretKey -InstanceID $SP2InstanceID;

            $AllServers = @($ADPublicDNS,$SQLPublicDNS,$SP1PublicDNS,$SP2PublicDNS);

			$checkresult = CheckServers -servers $AllServers
			
	        if($checkresult -ne "true")
	        {
	            " Trouble accessing one or more VMs";
	        }
			else
			{
			
				"All the VMs are up and running !!"
				
	            $spsmycreds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @("corp\SPFarm",(ConvertTo-SecureString -String "Passw0rd" -AsPlainText -Force))
	        
	            $Workflow:sp1VMName = inlineScript
	            {
	                Get-Content env:computername;
	            } -PSComputerName $SP1PublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck) -PSAuthentication CredSSP
	                    

	            "install SharePoint Farm on SP2013SRV1"
	            
	            inlineScript
	            {
	                ############################################################
	                # Configures a SharePoint 2013 farm with custom: 
	                # Configuration Database 
	                # Central Administation Database
	                # Central Administation web application and site 
	                ############################################################  

	                Add-PSSnapin Microsoft.SharePoint.PowerShell -erroraction SilentlyContinue   

	                ## Settings ## 
	                $configDatabaseName = "SP2013_Farm_SharePoint_Config"
	                $SQLServer = $Using:SQLVMName
	                $sqlServerAlias = $Using:SQLVMName
	                $caDatabaseName = "SP2013_Farm_Admin_Content"
	                $caPort = 2222 
	                $caAuthN = "NTLM" 
	                $passphrase = "pass@word1" 
	                $sPassphrase = (ConvertTo-SecureString -String $passphrase -AsPlainText -force)  

	                ######################################## 
	                # Create the SQL Alias 
	                ########################################  

	                $x86 = "HKLM:\Software\Microsoft\MSSQLServer\Client\ConnectTo"  
	                $x64 = "HKLM:\Software\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo"     
	                if ((test-path -path $x86) -ne $True)   
	                {  
	                    "$x86 doesn't exist"       
	                    New-Item $x86 
	                }   
	                if ((test-path -path $x64) -ne $True)  
	                {     
	                    "$x64 doesn't exist"  
	                    New-Item $x64 
	                }    

	                $TCPAlias = "DBMSSOCN," + $SQLServer  

	                New-ItemProperty -Path $x86 -Name $sqlServerAlias -PropertyType String -Value $TCPAlias  
	                New-ItemProperty -Path $x64 -Name $sqlServerAlias -PropertyType String -Value $TCPAlias   
	 
	                ######################################## 
	                # Create the farm 
	                ######################################## 
	                $password = "Passw0rd" | ConvertTo-SecureString -asPlainText -Force
	                $username = "$Using:FQDN\SPFarm" 
	                $credential = New-Object System.Management.Automation.PSCredential($username,$password)
	                $username;
	                "Creating the configuration database $configDatabaseName"  
	                New-SPConfigurationDatabase –DatabaseName $configDatabaseName –DatabaseServer $sqlServerAlias –AdministrationContentDatabaseName $caDatabaseName –Passphrase $sPassphrase –FarmCredentials $credential  
	                $farm = Get-SPFarm 

	                if (!$farm -or $farm.Status -ne "Online") 
	                { 
	                    "Farm was not created or is not running";
	                    exit;
	                }  

	                # Perform the config wizard tasks

	                "Initialize security"
	                Initialize-SPResourceSecurity  

	                "Install services"
	                Install-SPService  

	                "Register features"
	                Install-SPFeature -AllExistingFeatures  

	                "Create the Central Administration site on port $caPort" 
	                New-SPCentralAdministration -Port $caPort -WindowsAuthProvider $caAuthN  

	                "Install Help Collections"
	                Install-SPHelpCollection -All  

	                "Install Application Content" 
	                Install-SPApplicationContent  

	                New-ItemProperty HKLM:\System\CurrentControlSet\Control\Lsa -Name "DisableLoopbackCheck" -value "1" -PropertyType dword
	            } -PSComputerName $SP1PublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck) -PSAuthentication CredSSP
	               
	            "check if SP2013SRV2 is available"
	            
	            Start-Sleep -Seconds 60;
	            
	            PingServer -PublicDNS $SP2PublicDNS;

	            "Join SharePoint Server SP2013SRV2 to Farm."
	            inlineScript
	            {
	                ############################################################ 
	                # Joins a SharePoint 2013 Farm 
	                ############################################################  
	            
	                Add-PSSnapin Microsoft.SharePoint.PowerShell -erroraction SilentlyContinue   

	                ## Settings ## 
	                $configDatabaseName = "SP2013_Farm_SharePoint_Config" 
	                $SQLServer = $USING:SQLVMName 
	                $sqlServerAlias = $USING:SQLVMName
	                $passphrase = "pass@word1" 
	                $sPassphrase = (ConvertTo-SecureString -String $passphrase -AsPlainText -force)  

	                ######################################## 
	                # Create the SQL Alias 
	                ########################################  

	                $x86 = "HKLM:\Software\Microsoft\MSSQLServer\Client\ConnectTo"
	                $x64 = "HKLM:\Software\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo"
	                    
	                if ((test-path -path $x86) -ne $True)   
	                {       
	                    "$x86 doesn't exist"
	                    New-Item $x86   
	                }
	            
	                if ((test-path -path $x64) -ne $True)   
	                {      
	                    "$x64 doesn't exist"          
	                    New-Item $x64   
	                }
	            
	                $TCPAlias = "DBMSSOCN," + $SQLServer    
	            
	                New-ItemProperty -Path $x86 -Name $sqlServerAlias -PropertyType String -Value $TCPAlias   
	            
	                New-ItemProperty -Path $x64 -Name $sqlServerAlias -PropertyType String -Value $TCPAlias   

	                ######################################## 
	                # Connect to the farm 
	                ######################################## 
	            
	                "Connecting to the configuration database $configDatabaseName"  
	            
	                # psconfig -cmd upgrade -inplace b2b -wait -force 
	            
	                Connect-SPConfigurationDatabase -DatabaseServer $sqlServerAlias -DatabaseName $configDatabaseName -Passphrase $sPassphrase  
	                $farm = Get-SPFarm 
	                if (!$farm -or $farm.Status -ne "Online") 
	                {  
	                    "Farm was not connected or is not running"  
	                    exit
	                }  
	            
	                # Perform the config wizard tasks Write-Output "Initialize security" Initialize-SPResourceSecurity  
	        
	                "Install services" 
	                Install-SPService  
	                "Register features" 
	                Install-SPFeature -AllExistingFeatures  
	                New-ItemProperty HKLM:\System\CurrentControlSet\Control\Lsa -Name "DisableLoopbackCheck" -value "1" -PropertyType dword
	            }  -PSComputerName $SP2PublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck) -PSAuthentication CredSSP

	            "Provisioning SharePoint Services on SP2013SRV1
	             Execute other scripts to complete the installation."
	 
	            "check if SP2013SRV1 is available"
	             
	            PingServer -PublicDNS $SP1PublicDNS;

	            "Farm Initial Configuration"
	            inlineScript
	            {
					#run below script as farm 
					$Password = "Passw0rd"
					$credPass = convertto-securestring -AsPlainText -Force -String $Password
					$framcred = new-object -typename System.Management.Automation.PSCredential -argumentlist "Corp\SPFarm", $credPass

					 
					## Farm Initial Configuration ##  
					            
					Add-PSSnapin Microsoft.SharePoint.PowerShell -erroraction SilentlyContinue   
					            
					## Settings ## 
					$databaseServerName = $USING:SQLVMName 
					$saAppPoolName = "SharePoint Web Services" 
					$appPoolUserName = "corp\SPService"  
					            
					# Retrieve or create the services application pool and managed account 
					$saAppPool = Get-SPServiceApplicationPool -Identity $saAppPoolName -EA 0
					              
					if($saAppPool -eq $null)  
					{
					    "Creating Service Application Pool..."      
					    $appPoolAccount = Get-SPManagedAccount -Identity $appPoolUserName -EA 0    
					                
					    if($appPoolAccount -eq $null)    
					    {        
					        "Please supply the password for the Service Account..."       

					                    
					        $password = "Passw0rd" | ConvertTo-SecureString -asPlainText -Force
					        $username = $appPoolUserName
					        $appPoolCred = New-Object System.Management.Automation.PSCredential($username,$password)
					   
					        $appPoolAccount = New-SPManagedAccount -Credential $appPoolCred -EA 0    
					    }       
					                
					    $appPoolAccount = Get-SPManagedAccount -Identity $appPoolUserName -EA 0       
					                
					    if($appPoolAccount -eq $null)    
					    {      
					        "Cannot create or find the managed account $appPoolUserName, please ensure the account exists."    
					        Exit -1    
					    }    
					                
					    New-SPServiceApplicationPool -Name $saAppPoolName -Account $appPoolAccount -EA 0 > $null  
					} 
					               
					# provision the Web Analytics and Health Data Collection service, together with the Usage service, and the State service.  
					$usageSAName = "Usage and Health Data Collection Service" 
					$stateSAName = "State Service" 
					$stateServiceDatabaseName = "SP2013_Farm_StateDB"  


					# Configure the web analytics and health data collection service before creating the service  
					Set-SPUsageService -LoggingEnabled 1 -UsageLogLocation "C:\Program Files\Common Files\Microsoft Shared\Web Server Extensions\15\LOGS\" -UsageLogMaxSpaceGB 2  
					               
					# Usage Service Write-Host "Creating Usage Service and Proxy..." 
					$serviceInstance = Get-SPUsageService
					    New-SPUsageApplication -Name $usageSAName -DatabaseServer $databaseServerName -DatabaseName "SP2013_Farm_UsageDB" -UsageService $serviceInstance > $null  
					               
					# State Service 
					$stateServiceDatabase = New-SPStateServiceDatabase -Name $stateServiceDatabaseName 
					 
					$stateSA = New-SPStateServiceApplication -Name $stateSAName -Database $stateServiceDatabase
					New-SPStateServiceApplicationProxy -ServiceApplication $stateSA -Name "$stateSAName Proxy" -DefaultProxyGroup 

					# provision the Managed Metadata service application. 
					$metadataSAName = "Managed Metadata Service"  
					               
					# Managed Metadata Service 
					"Creating Metadata Service and Proxy..." 
					$mmsApp = New-SPMetadataServiceApplication -Name $metadataSAName -ApplicationPool $saAppPoolName -DatabaseServer $databaseServerName -DatabaseName "SP2013_Farm_MetadataDB" > $null 
					New-SPMetadataServiceApplicationProxy -Name "$metadataSAName Proxy" -DefaultProxyGroup -ServiceApplication $metadataSAName > $null 
					Get-SPServiceInstance | where-object {$_.TypeName -eq "Managed Metadata Web Service"} | Start-SPServiceInstance > $null 

					# Search Service - START # 
					               
					$searchMachines = @($USING:sp1VMName)
					$searchQueryMachines = @($USING:sp1VMName)
					$searchCrawlerMachines = @($USING:sp1VMName)
					$searchAdminComponentMachine = $USING:sp1VMName
					$searchSAName = "Search Service"
					$saAppPoolName = "SharePoint Web Services" 
					$databaseServerName = $SUSING:SQLVMName
					$searchDatabaseName = "SP2013_Farm_Search" 
					$indexLocation = "C:\SearchIndex"  

					cmd /c "mkdir $indexLocation"

					"Creating Search Service and Proxy..." 
					"  Starting Services..."  

					foreach ($machine in $searchMachines) 
					{    
					    "    Starting Search Services on $machine"    
					    Start-SPEnterpriseSearchQueryAndSiteSettingsServiceInstance $machine -ErrorAction SilentlyContinue     
					    Start-SPEnterpriseSearchServiceInstance $machine -ErrorAction SilentlyContinue 
					} 

					"  Creating Search Application..." 
					$searchApp = Get-SPEnterpriseSearchServiceApplication -Identity $searchSAName -ErrorAction SilentlyContinue

					if (!$searchApp) 
					{  
					    $searchApp = New-SPEnterpriseSearchServiceApplication -Name $SearchSAName -ApplicationPool $saAppPoolName -DatabaseServer $databaseServerName -DatabaseName $searchDatabaseName 
					} 

					$searchInstance = Get-SPEnterpriseSearchServiceInstance -Local  

					# Define the search topology 

					"  Defining the Search Topology..."
					$initialSearchTopology = $searchApp | Get-SPEnterpriseSearchTopology -Active
					$newSearchTopology = $searchApp | New-SPEnterpriseSearchTopology   

					# Create search components 

					"  Creating Admin Component..." 
					New-SPEnterpriseSearchAdminComponent -SearchTopology $newSearchTopology -SearchServiceInstance $searchInstance  
					 
					"  Creating Analytics Component..." 
					New-SPEnterpriseSearchAnalyticsProcessingComponent -SearchTopology $newSearchTopology -SearchServiceInstance $searchInstance  

					"  Creating Content Processing Component..." 
					New-SPEnterpriseSearchContentProcessingComponent -SearchTopology $newSearchTopology -SearchServiceInstance $searchInstance  

					"  Creating Query Processing Component..." 
					New-SPEnterpriseSearchQueryProcessingComponent -SearchTopology $newSearchTopology -SearchServiceInstance $searchInstance  

					"  Creating Crawl Component..." 
					New-SPEnterpriseSearchCrawlComponent -SearchTopology $newSearchTopology -SearchServiceInstance $searchInstance   

					"  Creating Index Component..." 
					New-SPEnterpriseSearchIndexComponent -SearchTopology $newSearchTopology -SearchServiceInstance $searchInstance -RootDirectory $indexLocation   

					"  Activating the new topology..."
					$newSearchTopology.Activate()  

					"  Creating Search Application Proxy..." 

					$searchProxy = Get-SPEnterpriseSearchServiceApplicationProxy -Identity "$searchSAName Proxy" -ErrorAction SilentlyContinue 

					if (!$searchProxy) 
					{    
					    New-SPEnterpriseSearchServiceApplicationProxy -Name "$searchSAName Proxy" -SearchApplication $searchSAName 
					} 
					 
					# Search Service - END # 

					# User Profile Service #

					"Creating User Profile Service and Proxy acting as Farm account..."
					$sb =  {  
					                Add-PSSnapin Microsoft.SharePoint.PowerShell -erroraction SilentlyContinue   
					                "Creating User Profile Service and Proxy acting as Farm account..."  
					                $saAppPoolNameForUPS = "SharePoint Web Services"  
					                $saAppPoolForUPS = Get-SPServiceApplicationPool -Identity $saAppPoolNameForUPS -EA 0   
					                $userUPSName = "User Profile Service"   
					                $databaseServerNameForUPS = $USING:SQLVMName
					                $userProfileService = New-SPProfileServiceApplication -Name $userUPSName -ApplicationPool $saAppPoolNameForUPS -ProfileDBServer $databaseServerNameForUPS -ProfileDBName "SP2013_Farm_ProfileDB" -SocialDBServer $databaseServerNameForUPS -SocialDBName "SP2013_Farm_SocialDB" -ProfileSyncDBServer $databaseServerNameForUPS -ProfileSyncDBName "SP2013_Farm_SyncDB" 
					                New-SPProfileServiceApplicationProxy -Name "$userUPSName Proxy" -ServiceApplication $userProfileService -DefaultProxyGroup > $null 
					            } 
					  
					$farmAccount = (Get-SPFarm).DefaultServiceAccount 
					           
					$password = "Passw0rd" | ConvertTo-SecureString -asPlainText -Force
					$username = $farmAccount 
					$farmCredential = New-Object System.Management.Automation.PSCredential($username,$password)
					           
					$job = Start-Job -Credential $farmCredential -ScriptBlock $sb | Wait-Job  

					Get-SPServiceInstance | where-object {$_.TypeName -eq "User Profile Service"} | Start-SPServiceInstance > $null

					$subSettingstName = "Subscription Settings Service1" 
					$subSettingstDatabaseName = "SP2013_Farm_SubSettingsDB1" 
					$appManagementName = "App Management Service1" 
					$appManagementDatabaseName = "SP2013_Farm_AppManagementDB1"  

					"Creating Subscription Settings Service and Proxy..." 
					$subSvc = New-SPSubscriptionSettingsServiceApplication –ApplicationPool $saAppPoolName –Name $subSettingstName –DatabaseName $subSettingstDatabaseName 
					$subSvcProxy = New-SPSubscriptionSettingsServiceApplicationProxy –ServiceApplication $subSvc 
					Get-SPServiceInstance | where-object {$_.TypeName -eq $subSettingstName} | Start-SPServiceInstance > $null  

				} -PSComputerName $SP1PublicDNS -PSCredential ($spsmycreds)  -PSUseSsl true -PSSessionOption(New-PSSessionOption -SkipCACheck -SkipCNCheck) -PSAuthentication CredSSP
	            
	            "=========================Configure SP Farm End============================="
			}
        }
    };
}

# Create SP Farm
cls
AWS-SP-Farm -AccessKey "[YourAccessKey]"  -SecretKey "[YourSecretKey]" -keyName "[YourKeyPairName]" #KeyPairName
#replace with your credentials before executing it.