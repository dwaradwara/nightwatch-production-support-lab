docker exec nightwatch-nginx sh -c "sed -i 's#nightwatch-api:8000#nightwatch-api:8999#' /etc/nginx/conf.d/default.conf && nginx -s reload" | Out-Null

Write-Host ""
Write-Host "INC-NW-004 injected."
Write-Host "Customer reports: Production API returns 502."