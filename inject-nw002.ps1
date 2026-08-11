$incident = Get-Random -Minimum 1 -Maximum 4

switch ($incident) {

    1 {
        docker stop nightwatch-api | Out-Null
    }

    2 {
        docker exec nightwatch-nginx sh -c "sed -i 's/nightwatch-api:8000/nightwatch-api:8999/' /etc/nginx/conf.d/default.conf && nginx -s reload" | Out-Null
    }

    3 {
        docker network disconnect nightwatch-net nightwatch-nginx | Out-Null
    }
}

Write-Host ""
Write-Host "INC-NW-002 injected."
Write-Host "Customer reports: Nightwatch production API is unavailable."
Write-Host "Determine the failing layer before making any change."