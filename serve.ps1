$port = 5500
$prefix = "http://localhost:$port/"
$siteRoot = (Get-Location).Path
$videoNewsFile = Join-Path $siteRoot 'video-news.json'
$videoRoot = Join-Path $siteRoot 'videos'
$dataRoot = Join-Path $siteRoot '.ehms-data'
$appointmentsFile = Join-Path $dataRoot 'appointments.json'
$pricesFile = Join-Path $dataRoot 'prices.json'
$maxVideoBytes = 250MB
$null = New-Item -ItemType Directory -Path $videoRoot -Force
$null = New-Item -ItemType Directory -Path $dataRoot -Force
$defaultPrices = [ordered]@{
    fauteuil = 7000
    matelas_simple = 10000
    matelas_double = 15000
    matelas_king = 20000
    tapis_petit = 5000
    tapis_moyen = 10000
    tapis_grand = 18000
    menage_studio = 20000
    menage_apt = 35000
    menage_villa = 50000
}
$adminCode = [Environment]::GetEnvironmentVariable('EHMS_ADMIN_CODE')
if ([string]::IsNullOrWhiteSpace($adminCode)) {
    $secureCode = Read-Host 'Choisis le code administrateur (12 caractères minimum)' -AsSecureString
    $codePointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureCode)
    try {
        $adminCode = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($codePointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($codePointer)
    }
}
if ($adminCode.Length -lt 12) {
    throw 'Le code administrateur doit contenir au moins 12 caractères.'
}
if (-not (Test-Path -LiteralPath $pricesFile -PathType Leaf)) {
    [System.IO.File]::WriteAllText($pricesFile, (ConvertTo-Json $defaultPrices -Depth 4), [System.Text.UTF8Encoding]::new($false))
}
$adminSessions = @{}
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Serveur HTTP démarré sur $prefix - Ctrl+C pour arrêter"

function Get-ContentType($ext) {
    switch ($ext.ToLower()) {
        '.html' { 'text/html' }
        '.htm' { 'text/html' }
        '.css' { 'text/css' }
        '.js' { 'application/javascript' }
        '.json' { 'application/json' }
        '.png' { 'image/png' }
        '.jpg' { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.svg' { 'image/svg+xml' }
        '.webp' { 'image/webp' }
        '.mp4' { 'video/mp4' }
        '.webm' { 'video/webm' }
        '.mov' { 'video/quicktime' }
        '.m4v' { 'video/x-m4v' }
        '.3gp' { 'video/3gpp' }
        default { 'application/octet-stream' }
    }
}

function Write-JsonResponse($response, $statusCode, $data) {
    $body = ConvertTo-Json -InputObject $data -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response.StatusCode = $statusCode
    $response.ContentType = 'application/json; charset=utf-8'
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-RawJsonResponse($response, $statusCode, $body) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response.StatusCode = $statusCode
    $response.ContentType = 'application/json; charset=utf-8'
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-JsonRequest($request) {
    if ($request.ContentLength64 -le 0 -or $request.ContentLength64 -gt 1048576) {
        throw 'Corps de requête vide ou trop volumineux.'
    }
    $reader = [System.IO.StreamReader]::new($request.InputStream, [System.Text.Encoding]::UTF8)
    try {
        return ConvertFrom-Json -InputObject $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Write-JsonFile($path, $data, [switch]$AsArray) {
    $temporaryFile = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        if ($AsArray) {
            $items = @($data)
            if ($items.Count -eq 0 -or ($items.Count -eq 1 -and $null -eq $items[0])) {
                $json = '[]'
            }
            else {
                $json = ConvertTo-Json -InputObject $items -Depth 8
            }
        }
        else {
            $json = ConvertTo-Json -InputObject $data -Depth 8
        }
        [System.IO.File]::WriteAllText($temporaryFile, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryFile -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
}

function Get-AdminSession($request) {
    $sessionId = $request.Cookies['ehms_admin_session'].Value
    if (-not $sessionId -or -not $adminSessions.ContainsKey($sessionId)) {
        return $false
    }
    if ($adminSessions[$sessionId] -le [DateTime]::UtcNow) {
        $adminSessions.Remove($sessionId)
        return $false
    }
    $adminSessions[$sessionId] = [DateTime]::UtcNow.AddHours(8)
    return $true
}

function Set-SessionCookie($request, $response, $sessionId, $expires) {
    $maxAge = if ($sessionId) { '28800' } else { '0' }
    $cookie = "ehms_admin_session=$sessionId; Path=/; HttpOnly; SameSite=Strict; Max-Age=$maxAge; Expires=$($expires.ToUniversalTime().ToString('R'))"
    if ($request.IsSecureConnection) { $cookie += '; Secure' }
    $response.AppendHeader('Set-Cookie', $cookie)
}

function Test-Prices($prices) {
    $keys = @($defaultPrices.Keys)
    foreach ($key in $keys) {
        $value = $prices.$key
        if ($null -eq $value -or $value -is [bool] -or
            [long]$value -lt 0 -or [long]$value -gt 100000000 -or
            [double]$value -ne [long]$value) {
            return $false
        }
    }
    return $true
}

function Test-SameOrigin($request) {
    $origin = $request.Headers['Origin']
    if (-not $origin) { return $true }
    return $origin -eq $request.Url.GetLeftPart([System.UriPartial]::Authority)
}

function Read-VideoNews {
    if (-not (Test-Path $videoNewsFile -PathType Leaf)) {
        return @()
    }
    $json = [System.IO.File]::ReadAllText($videoNewsFile, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    $items = ConvertFrom-Json -InputObject $json
    return @($items)
}

function Save-VideoNews($items) {
    $temporaryFile = Join-Path $siteRoot ("video-news.{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    $json = ConvertTo-Json -InputObject @($items) -Depth 6
    [System.IO.File]::WriteAllText($temporaryFile, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryFile -Destination $videoNewsFile -Force
}

function Send-VideoFile($response, $filePath, $rangeHeader) {
    $fileInfo = [System.IO.FileInfo]::new($filePath)
    $start = [long]0
    $end = $fileInfo.Length - 1
    $partial = $false

    if ($rangeHeader) {
        if ($rangeHeader -notmatch '^bytes=(\d*)-(\d*)$' -or $fileInfo.Length -eq 0) {
            $response.StatusCode = 416
            $response.Headers['Content-Range'] = "bytes */$($fileInfo.Length)"
            return
        }
        $partial = $true
        if ($Matches[1]) {
            $start = [long]$Matches[1]
            if ($Matches[2]) { $end = [long]$Matches[2] }
        }
        elseif ($Matches[2]) {
            $suffixLength = [long]$Matches[2]
            $start = [Math]::Max(0, $fileInfo.Length - $suffixLength)
        }
        else {
            $response.StatusCode = 416
            $response.Headers['Content-Range'] = "bytes */$($fileInfo.Length)"
            return
        }

        if ($start -ge $fileInfo.Length -or $end -lt $start) {
            $response.StatusCode = 416
            $response.Headers['Content-Range'] = "bytes */$($fileInfo.Length)"
            return
        }
        $end = [Math]::Min($end, $fileInfo.Length - 1)
    }

    $count = $end - $start + 1
    $response.StatusCode = if ($partial) { 206 } else { 200 }
    $response.ContentType = Get-ContentType $fileInfo.Extension
    $response.Headers['Accept-Ranges'] = 'bytes'
    if ($partial) {
        $response.Headers['Content-Range'] = "bytes $start-$end/$($fileInfo.Length)"
    }
    $response.ContentLength64 = $count

    $stream = [System.IO.File]::OpenRead($filePath)
    try {
        $stream.Position = $start
        $buffer = New-Object byte[] 65536
        while ($count -gt 0) {
            $read = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $count))
            if ($read -le 0) { break }
            try {
                $response.OutputStream.Write($buffer, 0, $read)
            }
            catch [System.Net.HttpListenerException] {
                break
            }
            catch [System.IO.IOException] {
                break
            }
            $count -= $read
        }
    }
    finally {
        $stream.Dispose()
    }
}

try {
    while ($true) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        if ($request.Url.AbsolutePath -eq '/api/admin-login') {
            try {
                if ($request.HttpMethod -ne 'POST') {
                    Write-JsonResponse $response 405 @{ error = 'Méthode non autorisée.' }
                }
                elseif (-not (Test-SameOrigin $request)) {
                    Write-JsonResponse $response 403 @{ error = 'Origine de requête non autorisée.' }
                }
                else {
                    $payload = Read-JsonRequest $request
                    if ([string]$payload.code -cne $adminCode) {
                        Write-JsonResponse $response 401 @{ error = 'Code d’accès incorrect.' }
                    }
                    else {
                        $sessionId = [Guid]::NewGuid().ToString('N')
                        $expires = [DateTime]::UtcNow.AddHours(8)
                        $adminSessions[$sessionId] = $expires
                        Set-SessionCookie $request $response $sessionId $expires
                        Write-JsonResponse $response 200 @{ authenticated = $true }
                    }
                }
            }
            catch {
                Write-JsonResponse $response 400 @{ error = $_.Exception.Message }
            }
            $response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq '/api/admin-session') {
            if ($request.HttpMethod -eq 'GET') {
                Write-JsonResponse $response 200 @{ authenticated = (Get-AdminSession $request) }
            }
            else {
                Write-JsonResponse $response 405 @{ error = 'Méthode non autorisée.' }
            }
            $response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq '/api/admin-logout') {
            if ($request.HttpMethod -eq 'POST' -and (Test-SameOrigin $request)) {
                $sessionId = $request.Cookies['ehms_admin_session'].Value
                if ($sessionId) { $adminSessions.Remove($sessionId) }
                Set-SessionCookie $request $response '' ([DateTime]::UtcNow.AddDays(-1))
                Write-JsonResponse $response 200 @{ authenticated = $false }
            }
            else {
                Write-JsonResponse $response 405 @{ error = 'Méthode non autorisée.' }
            }
            $response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq '/api/appointments') {
            try {
                if ($request.HttpMethod -eq 'GET') {
                    if (-not (Get-AdminSession $request)) {
                        Write-JsonResponse $response 401 @{ error = 'Authentification requise.' }
                    }
                    else {
                        $items = @()
                        if (Test-Path -LiteralPath $appointmentsFile -PathType Leaf) {
                            $saved = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($appointmentsFile, [System.Text.Encoding]::UTF8))
                            if ($null -ne $saved) { $items = @($saved) }
                        }
                        Write-JsonResponse $response 200 @{ items = $items }
                    }
                }
                elseif ($request.HttpMethod -eq 'POST') {
                    $payload = Read-JsonRequest $request
                    foreach ($field in @('nom', 'telephone', 'ville', 'message')) {
                        if ([string]::IsNullOrWhiteSpace([string]$payload.$field)) {
                            throw 'Tous les champs du rendez-vous sont obligatoires.'
                        }
                    }
                    if (([string]$payload.nom).Length -gt 120 -or ([string]$payload.telephone).Length -gt 40 -or
                        ([string]$payload.ville).Length -gt 120 -or ([string]$payload.message).Length -gt 2000) {
                        throw 'Un champ du rendez-vous dépasse la longueur autorisée.'
                    }
                    if (-not (Test-Path -LiteralPath $appointmentsFile -PathType Leaf)) {
                        [System.IO.File]::WriteAllText($appointmentsFile, '[]', [System.Text.UTF8Encoding]::new($false))
                    }
                    $savedItems = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($appointmentsFile, [System.Text.Encoding]::UTF8))
                    $items = if ($null -eq $savedItems) { @() } else { @($savedItems) }
                    $item = [ordered]@{
                        id = [Guid]::NewGuid().ToString()
                        nom = ([string]$payload.nom).Trim()
                        telephone = ([string]$payload.telephone).Trim()
                        ville = ([string]$payload.ville).Trim()
                        message = ([string]$payload.message).Trim()
                        createdAt = [DateTime]::UtcNow.ToString('o')
                        status = 'nouveau'
                    }
                    Write-JsonFile $appointmentsFile -data (@($item) + $items) -AsArray
                    Write-JsonResponse $response 201 $item
                }
                elseif ($request.HttpMethod -eq 'PUT' -or $request.HttpMethod -eq 'DELETE') {
                    if (-not (Test-SameOrigin $request) -or -not (Get-AdminSession $request)) {
                        Write-JsonResponse $response 401 @{ error = 'Authentification requise.' }
                    }
                    else {
                        $items = if ($request.HttpMethod -eq 'DELETE') { @() } else { @((Read-JsonRequest $request).items) }
                        foreach ($item in $items) {
                            if ([string]$item.id -notmatch '^[0-9a-f-]{36}$' -or
                                [string]$item.status -notin @('nouveau', 'traite') -or
                                [string]::IsNullOrWhiteSpace([string]$item.nom)) {
                                throw 'La liste de rendez-vous contient une entrée invalide.'
                            }
                        }
                        Write-JsonFile $appointmentsFile -data $items -AsArray
                        Write-JsonResponse $response 200 @{ items = $items }
                    }
                }
                else {
                    Write-JsonResponse $response 405 @{ error = 'Méthode non autorisée.' }
                }
            }
            catch {
                Write-Error "Erreur API rendez-vous : $_"
                Write-JsonResponse $response 400 @{ error = $_.Exception.Message }
            }
            $response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq '/api/prices') {
            try {
                if ($request.HttpMethod -eq 'GET') {
                    $prices = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($pricesFile, [System.Text.Encoding]::UTF8))
                    Write-JsonResponse $response 200 $prices
                }
                elseif ($request.HttpMethod -eq 'PUT') {
                    if (-not (Test-SameOrigin $request) -or -not (Get-AdminSession $request)) {
                        Write-JsonResponse $response 401 @{ error = 'Authentification requise.' }
                    }
                    else {
                        $prices = Read-JsonRequest $request
                        if (-not (Test-Prices $prices)) { throw 'Un ou plusieurs tarifs sont invalides.' }
                        Write-JsonFile $pricesFile $prices
                        Write-JsonResponse $response 200 $prices
                    }
                }
                else {
                    Write-JsonResponse $response 405 @{ error = 'Méthode non autorisée.' }
                }
            }
            catch {
                Write-Error "Erreur API tarifs : $_"
                Write-JsonResponse $response 400 @{ error = $_.Exception.Message }
            }
            $response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq '/api/video-news') {
            try {
                if ($request.HttpMethod -eq 'GET') {
                    $items = Read-VideoNews
                    foreach ($item in $items) {
                        if ([string]::IsNullOrWhiteSpace([string]$item.title) -or
                            ([string]$item.title).Length -gt 80 -or
                            ([string]$item.description).Length -gt 240 -or
                            ([string]$item.id) -notmatch '^[0-9a-f-]{36}$' -or
                            ([string]$item.extension) -notmatch '^\.(mp4|webm|mov|m4v|3gp)$') {
                            throw 'Le fichier contient une actualité vidéo invalide.'
                        }
                    }
                    $itemsJson = ConvertTo-Json -InputObject @($items) -Depth 6
                    Write-RawJsonResponse $response 200 "{`"items`":$itemsJson}"
                }
                else {
                    Write-JsonResponse $response 405 @{ error = 'Méthode non autorisée.' }
                }
            }
            catch {
                Write-Error "Erreur API actualités vidéo : $_"
                Write-JsonResponse $response 400 @{ error = $_.Exception.Message }
            }
            $response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq '/api/video-upload' -or $request.Url.AbsolutePath -eq '/api/video-delete') {
            $temporaryFile = $null
            $finalFile = $null
            try {
                if ($request.HttpMethod -ne 'POST') {
                    Write-JsonResponse $response 405 @{ error = 'Méthode non autorisée.' }
                }
                elseif (-not (Test-SameOrigin $request) -or -not (Get-AdminSession $request)) {
                    Write-JsonResponse $response 401 @{ error = 'Accès non autorisé.' }
                }
                elseif ($request.Url.AbsolutePath -eq '/api/video-upload') {
                    if ($request.ContentLength64 -le 0 -or $request.ContentLength64 -gt $maxVideoBytes) {
                        Write-JsonResponse $response 413 @{ error = 'La vidéo doit peser entre 1 octet et 250 Mo.' }
                    }
                    else {
                        $encodedMetadata = $request.Headers['X-Video-Metadata']
                        if (-not $encodedMetadata) { throw 'Les informations de la vidéo sont manquantes.' }
                        $metadataJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedMetadata))
                        $metadata = ConvertFrom-Json -InputObject $metadataJson
                        $title = ([string]$metadata.title).Trim()
                        $description = ([string]$metadata.description).Trim()
                        $extension = [System.IO.Path]::GetExtension([string]$metadata.fileName).ToLowerInvariant()
                        if ([string]::IsNullOrWhiteSpace($title) -or $title.Length -gt 80 -or $description.Length -gt 240) {
                            throw 'Le titre ou la description de la vidéo est invalide.'
                        }
                        if ($extension -notin @('.mp4', '.webm', '.mov', '.m4v', '.3gp')) {
                            throw 'Format vidéo non pris en charge. Choisis un fichier MP4, WebM, MOV, M4V ou 3GP.'
                        }

                        $id = [Guid]::NewGuid().ToString()
                        $fileName = "$id$extension"
                        $finalFile = Join-Path $videoRoot $fileName
                        $temporaryFile = "$finalFile.uploading"
                        $stream = [System.IO.File]::Open($temporaryFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                        try {
                            $request.InputStream.CopyTo($stream)
                        }
                        finally {
                            $stream.Dispose()
                        }
                        $savedBytes = (Get-Item -LiteralPath $temporaryFile).Length
                        if ($savedBytes -ne $request.ContentLength64 -or $savedBytes -gt $maxVideoBytes) {
                            throw 'L’envoi de la vidéo est incomplet ou dépasse la limite de 250 Mo.'
                        }

                        $item = [ordered]@{
                            id = $id
                            title = $title
                            description = $description
                            extension = $extension
                            url = "/videos/$fileName"
                            sizeBytes = $savedBytes
                            createdAt = [DateTime]::UtcNow.ToString('o')
                        }
                        $items = @(Read-VideoNews)
                        $items = @($item) + $items
                        Move-Item -LiteralPath $temporaryFile -Destination $finalFile
                        $temporaryFile = $null
                        try {
                            Save-VideoNews $items
                        }
                        catch {
                            Remove-Item -LiteralPath $finalFile -Force -ErrorAction SilentlyContinue
                            throw
                        }
                        Write-JsonResponse $response 201 $item
                    }
                }
                else {
                    $reader = [System.IO.StreamReader]::new($request.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                    $payload = ConvertFrom-Json -InputObject $body
                    $id = [string]$payload.id
                    if ($id -notmatch '^[0-9a-f-]{36}$') { throw 'Identifiant vidéo invalide.' }

                    $items = @(Read-VideoNews)
                    $item = $items | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
                    if (-not $item) {
                        Write-JsonResponse $response 404 @{ error = 'Vidéo introuvable.' }
                    }
                    else {
                        $items = @($items | Where-Object { [string]$_.id -ne $id })
                        Save-VideoNews $items
                        $extension = [string]$item.extension
                        if ($extension -notmatch '^\.(mp4|webm|mov|m4v|3gp)$') { throw 'Extension vidéo invalide.' }
                        $videoFile = Join-Path $videoRoot "$id$extension"
                        if (Test-Path -LiteralPath $videoFile -PathType Leaf) {
                            Remove-Item -LiteralPath $videoFile -Force
                        }
                        Write-JsonResponse $response 200 @{ deleted = $true }
                    }
                }
            }
            catch {
                Write-Error "Erreur API téléversement vidéo : $_"
                if ($temporaryFile -and (Test-Path -LiteralPath $temporaryFile)) {
                    Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
                }
                Write-JsonResponse $response 400 @{ error = $_.Exception.Message }
            }
            $response.OutputStream.Close()
            continue
        }

        $relative = $request.Url.LocalPath.TrimStart('/')
        if ([string]::IsNullOrEmpty($relative)) { $relative = 'index.html' }
        if ($relative -match '^videos/([0-9a-f-]{36}\.(mp4|webm|mov|m4v|3gp))$') {
            $videoPath = Join-Path $videoRoot $Matches[1]
            if (Test-Path -LiteralPath $videoPath -PathType Leaf) {
                Send-VideoFile $response $videoPath $request.Headers['Range']
                $response.OutputStream.Close()
                continue
            }
            $response.StatusCode = 404
            $response.OutputStream.Close()
            continue
        }
        $filePath = [System.IO.Path]::GetFullPath((Join-Path $siteRoot $relative))
        if (-not $filePath.StartsWith($siteRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $response.StatusCode = 404
            $response.OutputStream.Close()
            continue
        }
        $privateDataPrefix = [System.IO.Path]::GetFullPath($dataRoot) + [System.IO.Path]::DirectorySeparatorChar
        if ($filePath.StartsWith($privateDataPrefix, [StringComparison]::OrdinalIgnoreCase) -or $filePath -match '\.tmp$') {
            $response.StatusCode = 404
            $response.OutputStream.Close()
            continue
        }

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath)
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentType = Get-ContentType $ext
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        else {
            $response.StatusCode = 404
            $body = [System.Text.Encoding]::UTF8.GetBytes('404 - Not Found')
            $response.ContentType = 'text/plain'
            $response.ContentLength64 = $body.Length
            $response.OutputStream.Write($body, 0, $body.Length)
        }

        $response.OutputStream.Close()
    }
}
finally {
    $listener.Stop()
}
