$incident = Get-Random -Minimum 1 -Maximum 3

switch ($incident) {

    1 {
        docker exec nightwatch-nginx sh -c "sed -i 's#http://nightwatch-api:8000#http://nightwatch-api:8999#' /etc/nginx/conf.d/default.conf && nginx -s reload" | Out-Null
    }

    2 {
        docker exec nightwatch-nginx sh -c "sed -i 's#http://nightwatch-api:8000#http://127.0.0.1:8000#' /etc/nginx/conf.d/default.conf && nginx -s reload" | Out-Null
    }
}

Write-Host ""
Write-Host "INC-NW-003 injected."
Write-Host "Customer reports: Production API returns 502 Bad Gateway."
Write-Host "API container is reported healthy."