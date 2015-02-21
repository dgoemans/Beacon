properties { 
	$BaseDirectory = Resolve-Path .. 
    
    $ProjectName = "Beacon"
    
    $AssemblyVersion = "1.2.3.4"
	$InformationalVersion = "1.2.3-unstable.34+34.Branch.develop.Sha.19b2cd7f494c092f87a522944f3ad52310de79e0"
	$NuGetVersion = "1.2.3-unstable4"
	
	$PackageDirectory = "$BaseDirectory\Package"
	
	$SrcDir = "$BaseDirectory\Sources"
    $ReportsDir = "$BaseDirectory\TestResults"
	$SolutionFilePath = "$SrcDir\$ProjectName.sln"

    $NugetExe = "$BaseDirectory\Tools\nuget.exe"
    $GitVersionExe = "$BaseDirectory\Tools\GitVersion.exe"
}

TaskSetup {
    TeamCity-ReportBuildProgress "Starting task $($psake.context.Peek().currentTaskName)"
}

TaskTearDown {
    TeamCity-ReportBuildProgress "Finished task $($psake.context.Peek().currentTaskName)"
}

task default -depends Clean, ExtractVersionsFromGit, RestoreNugetPackages, ApplyAssemblyVersioning, ApplyPackageVersioning, Compile, CreateChocoPackages

task Clean -Description "Cleaning solution." {
	Get-ChildItem $PackageDirectory *.nupkg | ForEach { Remove-Item $_.FullName }
	Get-ChildItem $PackageDirectory *.zip | ForEach { Remove-Item $_.FullName }
	
	exec { msbuild /nologo /verbosity:minimal $SolutionFilePath /t:Clean /p:VSToolsPath="$SrcDir\Packages\MSBuild.Microsoft.VisualStudio.Web.targets.11.0.2.1\tools\VSToolsPath" }    
}

task ExtractVersionsFromGit {
        $json = . "$GitVersionExe" 
        
        if ($LASTEXITCODE -eq 0) {
            $version = (ConvertFrom-Json ($json -join "`n"));
          
            TeamCity-SetBuildNumber $version.FullSemVer;
            
            $script:AssemblyVersion = $version.ClassicVersion;
            $script:InformationalVersion = $version.InformationalVersion;
            $script:NuGetVersion = $version.NuGetVersionV2;
        }
        else {
            Write-Output $json -join "`n";
        }
}

task RestoreNugetPackages {
    $packageConfigs = Get-ChildItem $BaseDirectory -Recurse | where{$_.Name -eq "packages.config"}

    foreach($packageConfig in $packageConfigs){
    	Write-Host "Restoring" $packageConfig.FullName 
    	exec { 
            . "$NugetExe" install $packageConfig.FullName -OutputDirectory "$SrcDir\Packages" -ConfigFile "$SrcDir\.nuget\NuGet.Config"
        }
    }
}

task ApplyAssemblyVersioning -depends ExtractVersionsFromGit {
	Get-ChildItem -Path $SrcDir -Filter "?*AssemblyInfo.cs" -Recurse -Force |
	foreach-object {  

		Set-ItemProperty -Path $_.FullName -Name IsReadOnly -Value $false

        $content = Get-Content $_.FullName
        
        if ($script:AssemblyVersion) {
    		Write-Host "Updating " $_.FullName "with version" $script:AssemblyVersion
    	    $content = $content -replace 'AssemblyVersion\("(.+)"\)', ('AssemblyVersion("' + $script:AssemblyVersion + '")')
            $content = $content -replace 'AssemblyFileVersion\("(.+)"\)', ('AssemblyFileVersion("' + $script:AssemblyVersion + '")')
        }
		
        if ($script:InformationalVersion) {
    		Write-Host "Updating " $_.FullName "with information version" $script:InformationalVersion
            $content = $content -replace 'AssemblyInformationalVersion\("(.+)"\)', ('AssemblyInformationalVersion("' + $script:InformationalVersion + '")')
        }
        
	    Set-Content -Path $_.FullName $content
	}    
}

task ApplyPackageVersioning -depends ExtractVersionsFromGit {
    TeamCity-Block "Updating package version with build number $BuildNumber" {   
	
		$fullName = "$PackageDirectory\.nuspec"

	    Set-ItemProperty -Path $fullName -Name IsReadOnly -Value $false
		
	    $content = Get-Content $fullName
	    $content = $content -replace '<version>.+</version>', ('<version>' + "$script:NuGetVersion" + '</version>')
	    Set-Content -Path $fullName $content
	}
}

task Compile -Description "Compiling solution." { 
	exec { msbuild /nologo /verbosity:minimal $SolutionFilePath /p:Configuration=Release /p:VSToolsPath="$SrcDir\Packages\MSBuild.Microsoft.VisualStudio.Web.targets.11.0.2.1\tools\VSToolsPath" }
}

task RunTests -depends Compile -Description "Running all unit tests." {
	$xunitRunner = "$SrcDir\packages\xunit.runners.1.9.2\tools\xunit.console.clr4.exe"
	gci $SrcDir -Recurse -Include *Specs.csproj | % {
		$project = $_.BaseName
		if(!(Test-Path $ReportsDir\xUnit\$project)){
			New-Item $ReportsDir\xUnit\$project -Type Directory
		}
        
		exec { . $xunitRunner "$SrcDir\$project\bin\Release\$project.dll" /html "$ReportsDir\xUnit\$project\index.html" }
	}
}

task CreateChocoPackages -depends ApplyPackageVersioning, ApplyAssemblyVersioning -Description "Creating Chocolatey package." {
	if (!$env:ChocolateyInstall) {
		Write-Host "Installing Chocolatey"
		iex ((new-object net.webclient).DownloadString('http://bit.ly/psChocInstall')) 
  	}

	exec { 
        $lastcd = $PWD;
		cd $PackageDirectory
		
		choco pack .nuspec
		
		cd $lastcd;
    }
}