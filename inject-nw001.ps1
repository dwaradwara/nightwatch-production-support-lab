$incident = Get-Random -Minimum 1 -Maximum 3

switch ($incident) {

    1 {
        docker network disconnect nightwatch-net nightwatch-api | Out-Null
    }

    2 {
        docker network disconnect nightwatch-net nightwatch-nginx | Out-Null
    }

}

Write-Host ""
Write-Host "INC-NW-001 injected."
Write-Host "Customer reports: API unavailable through production endpoint."
Write-Host "Do not inspect this script again until investigation is complete."