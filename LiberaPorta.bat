<# :
@echo off
setlocal
title LiberaPorta
rem ==========================================================================
rem  LiberaPorta - libera/fecha portas para acessar o servidor pelo navegador
rem  Uso: duplo clique (menu) ou  LiberaPorta.cmd abrir 8080 | fechar 8080
rem ==========================================================================
net session >nul 2>&1
if errorlevel 1 (
  echo Solicitando permissao de Administrador...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%* /elevado' -Verb RunAs"
  exit /b
)
set "LP_ARGS=%*"
set "LP_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:LP_SELF,[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($c))"
exit /b %errorlevel%
#>

# =============================================================================
#  LiberaPorta (parte PowerShell)
#  - Detecta Windows 10/11 e o IP da máquina na rede (prioriza o Wi-Fi)
#  - Abre a porta no Firewall apenas para a rede local (LocalSubnet)
#  - Se a aplicação escuta só em localhost, cria redirecionamento (portproxy)
#  - Antes de liberar/fechar, verifica se a porta já está liberada/fechada
#  - Registra tudo em C:\ProgramData\LiberaPorta\estado.json para desfazer
# =============================================================================
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Versao    = '1.1'
$Grupo     = 'LiberaPorta'
$Pasta     = Join-Path $env:ProgramData 'LiberaPorta'
$ArqEstado = Join-Path $Pasta 'estado.json'
$ArqLog    = Join-Path $Pasta 'liberaporta.log'
# Apenas AVISO: nenhuma porta é liberada automaticamente; você sempre informa a porta.
$PortasSensiveis = @{
    21 = 'FTP'; 22 = 'SSH'; 23 = 'Telnet'; 135 = 'RPC do Windows'; 139 = 'NetBIOS'
    445 = 'Compartilhamento de arquivos (SMB)'; 3389 = 'Área de Trabalho Remota'
    5985 = 'WinRM'; 5986 = 'WinRM'
}

$Argumentos = @()
if ($env:LP_ARGS) { $Argumentos = @($env:LP_ARGS -split '\s+' | Where-Object { $_ }) }
$Elevado    = $Argumentos -contains '/elevado'
$Argumentos = @($Argumentos | Where-Object { $_ -ne '/elevado' })

if (-not (Test-Path $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force | Out-Null }

# ----------------------------------------------------------------- utilitários
function Escreva {
    param([string]$Texto = '', [string]$Cor = 'Gray')
    Write-Host $Texto -ForegroundColor $Cor
}

function Write-Log {
    param([string]$Msg)
    try { Add-Content -Path $ArqLog -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Msg) -Encoding UTF8 } catch {}
}

function Invoke-Netsh {
    param([string[]]$Parametros)
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $saida  = (& netsh.exe @Parametros 2>&1 | Out-String).Trim()
        $codigo = $LASTEXITCODE
    } finally { $ErrorActionPreference = $antes }
    [pscustomobject]@{ Saida = $saida; Codigo = $codigo }
}

function Test-Tcp {
    param([string]$Endereco, [int]$Porta, [int]$Timeout = 1500)
    $cli = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $cli.ConnectAsync($Endereco, $Porta)
        return ($t.Wait($Timeout) -and $cli.Connected)
    } catch { return $false } finally { $cli.Close() }
}

function ConvertTo-Porta {
    param($Valor)
    $n = 0
    if ([int]::TryParse(([string]$Valor).Trim(), [ref]$n) -and $n -ge 1 -and $n -le 65535) { return $n }
    return $null
}

function Format-Endereco {
    param([string]$Ip, [int]$Porta)
    if ($Ip -like '*:*') { return "[$Ip]:$Porta" }
    return "${Ip}:$Porta"
}

function Show-Faixa {
    param([string[]]$Linhas, [string]$Cor = 'Green')
    Escreva ''
    Escreva ('=' * 64) $Cor
    foreach ($l in $Linhas) { Escreva "  $l" $Cor }
    Escreva ('=' * 64) $Cor
}

# ---------------------------------------------------------- sistema e rede
function Get-InfoSistema {
    $os    = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -lt 10240) {
        throw "Este utilitário foi feito para Windows 10 e 11. Sistema detectado: $($os.Caption) (build $build)."
    }
    $familia = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    $edicao  = ($os.Caption -replace '^Microsoft\s+', '') -replace 'Windows 1[01]', $familia
    $versao  = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
    [pscustomobject]@{ Familia = $familia; Edicao = $edicao; Build = $build; Versao = $versao }
}

function Get-RedeLocal {
    $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' })
    if (-not $cfgs) { return $null }
    $wifi = @($cfgs | Where-Object {
        $_.NetAdapter.PhysicalMediaType -match '802\.11|Wireless' -or $_.InterfaceAlias -match 'Wi-?Fi|WLAN|Wireless|Sem Fio'
    })
    $sel    = if ($wifi) { $wifi[0] } else { $cfgs[0] }
    $perfil = (Get-NetConnectionProfile -InterfaceIndex $sel.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory
    [pscustomobject]@{
        IP        = @($sel.IPv4Address)[0].IPAddress
        Interface = $sel.InterfaceAlias
        Indice    = $sel.InterfaceIndex
        Perfil    = [string]$perfil
        Wifi      = [bool]$wifi
    }
}

# --------------------------------------------------- redirecionamento (proxy)
function Get-Proxies {
    $lista = @()
    foreach ($tipo in 'v4tov4', 'v4tov6') {
        $chave = "HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\$tipo\tcp"
        if (-not (Test-Path $chave)) { continue }
        $props = (Get-ItemProperty $chave).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }
        foreach ($pr in $props) {
            $esc = $pr.Name.Split('/')
            $dst = ([string]$pr.Value).Split('/')
            $lista += [pscustomobject]@{
                Tipo = $tipo; Escuta = $esc[0]; Porta = [int]$esc[1]
                Destino = $dst[0]; PortaDestino = [int]$dst[1]
            }
        }
    }
    return $lista
}

function Remove-Proxy {
    param([string]$Escuta, [int]$Porta)
    $removidos = 0
    foreach ($px in @(Get-Proxies | Where-Object { $_.Porta -eq $Porta -and $_.Escuta -eq $Escuta })) {
        Invoke-Netsh @('interface', 'portproxy', 'delete', $px.Tipo, "listenaddress=$($px.Escuta)", "listenport=$Porta") | Out-Null
        $removidos++
    }
    return $removidos
}

function Start-IPHelper {
    $s = Get-Service iphlpsvc -ErrorAction SilentlyContinue
    if (-not $s) { throw 'Serviço "Auxiliar IP" (iphlpsvc) não encontrado; ele é necessário para o redirecionamento.' }
    if ([string]$s.StartType -eq 'Disabled') { Set-Service iphlpsvc -StartupType Automatic }
    if ($s.Status -ne 'Running') { Start-Service iphlpsvc }
}

# ------------------------------------------------------ quem escuta na porta
function Get-Escuta {
    param([int]$Porta, [string]$IPRede)
    $lista = @(Get-NetTCPConnection -State Listen -LocalPort $Porta -ErrorAction SilentlyContinue)
    # ignora o próprio redirecionamento criado por esta ferramenta
    $nossos = @(Get-Proxies | Where-Object { $_.Porta -eq $Porta } | ForEach-Object { $_.Escuta })
    if ($nossos) { $lista = @($lista | Where-Object { $nossos -notcontains $_.LocalAddress }) }

    $enderecos = @($lista | ForEach-Object { $_.LocalAddress } | Select-Object -Unique)
    $modo = 'Nenhum'
    if (@($enderecos | Where-Object { $_ -in @('0.0.0.0', '::', $IPRede) }).Count) { $modo = 'Rede' }
    elseif ($enderecos -contains '127.0.0.1') { $modo = 'Local4' }
    elseif ($enderecos -contains '::1')       { $modo = 'Local6' }
    elseif ($enderecos.Count)                 { $modo = 'Outro' }

    $proc = $null
    if ($lista) { $proc = Get-Process -Id $lista[0].OwningProcess -ErrorAction SilentlyContinue }
    $caminho = $null
    if ($proc) { try { $caminho = $proc.Path } catch {} }
    [pscustomobject]@{
        Modo      = $modo
        Enderecos = $enderecos
        Processo  = $(if ($proc) { $proc.ProcessName } else { $null })
        Caminho   = $caminho
    }
}

# ------------------------------------------------------------------- firewall
function Add-RegraFirewall {
    param([int]$Porta)
    $nome = "LiberaPorta-TCP-$Porta"
    Get-NetFirewallRule -Name $nome -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $nome -DisplayName "LiberaPorta - TCP $Porta" -Group $Grupo `
        -Description 'Criada pelo LiberaPorta. Remova pelo próprio utilitário (Fechar porta).' `
        -Direction Inbound -Protocol TCP -LocalPort $Porta -Action Allow `
        -RemoteAddress LocalSubnet -Profile Any -Enabled True | Out-Null
    return $nome
}

function Test-PortaNaLista {
    # aceita valores como "8080", "8000-8100" ou listas
    param($Lista, [int]$Porta)
    foreach ($i in @($Lista)) {
        $s = [string]$i
        if ($s -match '^\d+$' -and [int]$s -eq $Porta) { return $true }
        if ($s -match '^(\d+)-(\d+)$' -and $Porta -ge [int]$Matches[1] -and $Porta -le [int]$Matches[2]) { return $true }
    }
    return $false
}

function Test-RegraPermite {
    # regra de ENTRADA, PERMITIR, ATIVA e valendo para o perfil de rede atual
    param($Regra, [string]$Perfil)
    if ([string]$Regra.Direction -ne 'Inbound' -or [string]$Regra.Action -ne 'Allow' -or [string]$Regra.Enabled -ne 'True') { return $false }
    $p = [string]$Regra.Profile
    if ($p -eq 'Any' -or -not $Perfil) { return $true }
    $alvo = if ($Perfil -eq 'DomainAuthenticated') { 'Domain' } else { $Perfil }
    return ($p -match $alvo)
}

function Get-RegrasPrograma {
    # regras ligadas ao executável da aplicação (ex.: node.exe, python.exe)
    param([string]$Caminho)
    if (-not $Caminho) { return @() }
    return @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Program -and [Environment]::ExpandEnvironmentVariables($_.Program) -eq $Caminho } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue)
}

function Get-BloqueiosPrograma {
    param([string]$Caminho)
    return @(Get-RegrasPrograma $Caminho | Where-Object {
        [string]$_.Direction -eq 'Inbound' -and [string]$_.Action -eq 'Block' -and [string]$_.Enabled -eq 'True' })
}

function Get-StatusPorta {
    # Responde: a porta está liberada (acessível pela rede) ou não?
    param([int]$Porta, $Rede)
    $ip     = $Rede.IP
    $perfil = $Rede.Perfil
    $nomeNossa = "LiberaPorta-TCP-$Porta"
    $esc = Get-Escuta -Porta $Porta -IPRede $ip

    $nossa      = Get-NetFirewallRule -Name $nomeNossa -ErrorAction SilentlyContinue
    $nossaAtiva = [bool]($nossa | Where-Object { [string]$_.Enabled -eq 'True' })

    # outras regras do Windows que liberam esta porta TCP
    $porPorta = @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue |
        Where-Object { Test-PortaNaLista $_.LocalPort $Porta } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $nomeNossa -and (Test-RegraPermite $_ $perfil) })
    $nomesPorta = @($porPorta | ForEach-Object { $_.Name })

    # regras do programa que está escutando (liberam qualquer porta dele)
    $porPrograma = @(Get-RegrasPrograma $esc.Caminho | Where-Object {
        $_.Name -ne $nomeNossa -and $nomesPorta -notcontains $_.Name -and (Test-RegraPermite $_ $perfil)
    } | Where-Object {
        $pf = $_ | Get-NetFirewallPortFilter
        ([string]$pf.Protocol -in @('Any', 'TCP')) -and ([string]$pf.LocalPort -eq 'Any' -or (Test-PortaNaLista $pf.LocalPort $Porta))
    })

    $proxy = Get-Proxies | Where-Object { $_.Porta -eq $Porta -and $_.Escuta -eq $ip } | Select-Object -First 1
    $precisaProxy = $esc.Modo -in @('Local4', 'Local6', 'Outro')
    $proxyOk = [bool]($proxy -and $esc.Enderecos -contains $proxy.Destino)
    $firewallOk = $nossaAtiva -or ($porPorta.Count -gt 0) -or ($porPrograma.Count -gt 0)

    [pscustomobject]@{
        Escuta         = $esc
        RegraNossa     = [bool]$nossa
        RegraNossaAtiva = $nossaAtiva
        RegrasPorta    = $porPorta
        RegrasPrograma = $porPrograma
        Proxy          = $proxy
        FirewallOk     = [bool]$firewallOk
        PrecisaProxy   = $precisaProxy
        ProxyOk        = $proxyOk
        Liberada       = [bool]($firewallOk -and ((-not $precisaProxy) -or $proxyOk))
    }
}

function Show-MotivosLiberada {
    param($St, [int]$Porta)
    if ($St.RegraNossaAtiva) { Escreva '    - regra do LiberaPorta ativa no firewall' }
    foreach ($r in $St.RegrasPorta)    { Escreva "    - regra do Windows: $($r.DisplayName)" }
    foreach ($r in $St.RegrasPrograma) { Escreva "    - regra do programa $($St.Escuta.Processo): $($r.DisplayName)" }
    if ($St.ProxyOk) { Escreva "    - redirecionamento ativo para $(Format-Endereco $St.Proxy.Destino $Porta)" }
}

# --------------------------------------------------------------------- estado
function Get-Estado {
    if (-not (Test-Path $ArqEstado)) { return @() }
    try {
        $d = Get-Content -Path $ArqEstado -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($d | Where-Object { $_ })
    } catch { return @() }
}

function Save-Estado {
    param($Lista)
    ConvertTo-Json -InputObject @($Lista) -Depth 5 | Set-Content -Path $ArqEstado -Encoding UTF8
}

function Sync-IP {
    # Se o IP do Wi-Fi mudou (DHCP), refaz os redirecionamentos no novo IP
    $estado = @(Get-Estado)
    if (-not $estado) { return $false }
    $rede = Get-RedeLocal
    if (-not $rede) { return $false }
    $mudou = $false
    foreach ($it in $estado) {
        if ($it.IP -eq $rede.IP) { continue }
        if ($it.Modo -eq 'Proxy') {
            Remove-Proxy -Escuta $it.IP -Porta $it.Porta | Out-Null
            Start-IPHelper
            Invoke-Netsh @('interface', 'portproxy', 'add', $it.TipoProxy, "listenaddress=$($rede.IP)",
                "listenport=$($it.Porta)", "connectaddress=$($it.Destino)", "connectport=$($it.Porta)") | Out-Null
        }
        Escreva "O IP da máquina mudou ($($it.IP) -> $($rede.IP)). Porta $($it.Porta) atualizada: $($rede.IP):$($it.Porta)" Yellow
        $it.IP = $rede.IP
        $mudou = $true
    }
    if ($mudou) { Save-Estado $estado; Write-Log "IP atualizado para $($rede.IP)" }
    return $mudou
}

# ============================================================ LIBERAR PORTA
function Open-Porta {
    param([int]$Porta, [switch]$Silencioso)

    $rede = Get-RedeLocal
    if (-not $rede) { throw 'Não encontrei conexão de rede ativa (Wi-Fi ou cabo). Conecte a máquina à rede e tente de novo.' }

    # ---- 1) VERIFICAÇÃO: a porta já está liberada?
    Escreva "Verificando se a porta $Porta já está liberada..." Cyan
    $st = Get-StatusPorta -Porta $Porta -Rede $rede
    if ($st.Liberada) {
        Escreva "  Resultado: SIM, a porta $Porta já está liberada. Nada foi alterado." Yellow
        Show-MotivosLiberada $st $Porta
        if ($st.Escuta.Modo -eq 'Nenhum') {
            Escreva "  Obs.: nenhuma aplicação está rodando na porta $Porta neste momento." Yellow
        }
        Show-Faixa @(
            "Nas outras máquinas, abra o navegador e digite: http://$($rede.IP):$Porta",
            '',
            "A PORTA JÁ ESTAVA LIBERADA PARA ACESSO  >>>  $($rede.IP):$Porta"
        ) 'Yellow'
        try { Set-Clipboard -Value "http://$($rede.IP):$Porta" } catch {}
        return
    }
    Escreva "  Resultado: NÃO, a porta $Porta está fechada. Iniciando a liberação..." Cyan
    if ($st.FirewallOk -and $st.PrecisaProxy) {
        Escreva '  (o firewall já permitia, mas faltava o redirecionamento até a aplicação)'
    }

    # aviso para portas de serviços do Windows (não impede a liberação)
    if ($PortasSensiveis.ContainsKey($Porta)) {
        Escreva "  ATENÇÃO: a porta $Porta costuma ser de $($PortasSensiveis[$Porta]). Liberá-la expõe esse serviço na rede." Yellow
        if (-not $Silencioso -and (Read-Host '  Deseja continuar? (S/N)') -notmatch '^[sS]') { Escreva '  Operação cancelada.' Yellow; return }
    }

    # ---- 2) LIBERAÇÃO
    $anterior = @(Get-Estado) | Where-Object { $_.Porta -eq $Porta } | Select-Object -First 1
    $esc  = $st.Escuta
    $modo = 'Direto'; $tipo = $null; $destino = $null
    $app  = if ($esc.Processo) { "'$($esc.Processo)'" } else { 'A aplicação' }
    switch ($esc.Modo) {
        'Rede'   { Escreva "  $app já escuta na rede. Basta abrir o firewall." }
        'Local4' { $modo = 'Proxy'; $tipo = 'v4tov4'; $destino = '127.0.0.1'
                   Escreva "  $app escuta só em localhost (127.0.0.1). Vou criar o redirecionamento da rede para ela." }
        'Local6' { $modo = 'Proxy'; $tipo = 'v4tov6'; $destino = '::1'
                   Escreva "  $app escuta só em localhost IPv6 (::1). Vou criar o redirecionamento da rede para ela." }
        'Outro'  { $modo = 'Proxy'; $destino = $esc.Enderecos[0]
                   $tipo = if ($destino -like '*:*') { 'v4tov6' } else { 'v4tov4' }
                   Escreva "  $app escuta em $destino. Vou redirecionar o IP da rede para esse endereço." }
        'Nenhum' { Escreva "  Nenhuma aplicação está rodando na porta $Porta agora. Vou abrir o firewall mesmo assim." Yellow
                   Escreva '  Dica: se a aplicação, ao subir, ficar só em localhost, use "Liberar" de novo com ela aberta.' Yellow }
    }

    # regras que BLOQUEIAM o programa (ex.: clicou "Cancelar" no aviso do firewall)
    $bloqueiosDesativados = @()
    if ($anterior) { $bloqueiosDesativados += @($anterior.BloqueiosDesativados | Where-Object { $_ }) }
    if ($modo -eq 'Direto' -and $esc.Caminho) {
        $bloq = @(Get-BloqueiosPrograma $esc.Caminho)
        if ($bloq) {
            Escreva "  Há $($bloq.Count) regra(s) do firewall BLOQUEANDO $($esc.Processo):" Yellow
            $bloq | ForEach-Object { Escreva "    - $($_.DisplayName)" Yellow }
            $ok = $Silencioso -or ((Read-Host '  Desativar enquanto a porta estiver liberada? (S/N)') -match '^[sS]')
            if ($ok) {
                foreach ($b in $bloq) { Disable-NetFirewallRule -Name $b.Name; $bloqueiosDesativados += $b.Name }
                Escreva '  Regras de bloqueio desativadas (voltam ao fechar a porta).' Green
            }
        }
    }

    # firewall
    $regra = Add-RegraFirewall -Porta $Porta
    Escreva "  Firewall: regra '$regra' criada (TCP $Porta, somente rede local)." Green

    # redirecionamento (remove um antigo/errado antes)
    if ((Remove-Proxy -Escuta $rede.IP -Porta $Porta) -gt 0) { Start-Sleep -Milliseconds 300 }
    if ($modo -eq 'Proxy') {
        Start-IPHelper
        $r = Invoke-Netsh @('interface', 'portproxy', 'add', $tipo, "listenaddress=$($rede.IP)",
            "listenport=$Porta", "connectaddress=$destino", "connectport=$Porta")
        if ($r.Codigo -ne 0) { throw "Falha ao criar o redirecionamento: $($r.Saida)" }
        Escreva "  Redirecionamento: $(Format-Endereco $rede.IP $Porta) -> $(Format-Endereco $destino $Porta)" Green
    }

    # estado + log
    $estado  = @(@(Get-Estado) | Where-Object { $_.Porta -ne $Porta })
    $estado += [pscustomobject]@{
        Porta = $Porta; IP = $rede.IP; Modo = $modo; TipoProxy = $tipo; Destino = $destino
        Regra = $regra; BloqueiosDesativados = @($bloqueiosDesativados | Select-Object -Unique)
        Processo = $esc.Processo; Windows = "$($Sistema.Edicao) build $($Sistema.Build)"
        Data = (Get-Date).ToString('dd/MM/yyyy HH:mm')
    }
    Save-Estado $estado
    Write-Log "LIBERADA porta $Porta | modo $modo | IP $($rede.IP) | app $($esc.Processo)"

    # teste
    if ($esc.Modo -ne 'Nenhum') {
        Start-Sleep -Milliseconds 600
        if (Test-Tcp $rede.IP $Porta) { Escreva "  Teste: a porta respondeu em $($rede.IP):$Porta." Green }
        else { Escreva '  Teste: a porta ainda não respondeu. Use a opção "Diagnosticar porta".' Yellow }
    }

    $url = "http://$($rede.IP):$Porta"
    try { Set-Clipboard -Value $url } catch {}
    Show-Faixa @(
        "Nas outras máquinas, abra o navegador e digite: $url",
        '(endereço já copiado para a área de transferência)',
        '',
        "LIBERADO PARA ACESSO NA REDE  >>>  $($rede.IP):$Porta"
    ) 'Green'
}

# ============================================================= FECHAR PORTA
function Close-Porta {
    param([int]$Porta, [switch]$Silencioso)
    $estado = @(Get-Estado)
    $item   = $estado | Where-Object { $_.Porta -eq $Porta } | Select-Object -First 1
    $rede   = Get-RedeLocal
    $ipMostrar = if ($rede) { $rede.IP } elseif ($item) { $item.IP } else { 'IP' }

    # ---- 1) VERIFICAÇÃO: a porta já está fechada?
    Escreva "Verificando se a porta $Porta já está fechada..." Cyan
    $nome  = "LiberaPorta-TCP-$Porta"
    $regra = Get-NetFirewallRule -Name $nome -ErrorAction SilentlyContinue
    $ips   = @(@($item.IP, $rede.IP) | Where-Object { $_ } | Select-Object -Unique)
    $proxies = @(Get-Proxies | Where-Object { $_.Porta -eq $Porta -and $ips -contains $_.Escuta })
    $externas = @()
    if ($rede) {
        $st = Get-StatusPorta -Porta $Porta -Rede $rede
        $externas = @($st.RegrasPorta) + @($st.RegrasPrograma)
    }

    if (-not $regra -and -not $proxies -and -not $item -and -not $externas) {
        Escreva "  Resultado: SIM, a porta $Porta já está fechada. Nada foi alterado." Yellow
        Show-Faixa @(
            "A PORTA JÁ ESTAVA FECHADA  >>>  $($ipMostrar):$Porta não está acessível na rede"
        ) 'Yellow'
        return
    }
    Escreva "  Resultado: NÃO, a porta $Porta está aberta. Iniciando o fechamento..." Cyan

    # ---- 2) FECHAMENTO do que o LiberaPorta criou
    if ($regra) { $regra | Remove-NetFirewallRule; Escreva "  Firewall: regra '$nome' removida." Green }
    foreach ($px in $proxies) {
        Remove-Proxy -Escuta $px.Escuta -Porta $Porta | Out-Null
        Escreva "  Redirecionamento $(Format-Endereco $px.Escuta $Porta) removido." Green
    }
    if ($item) {
        foreach ($n in @($item.BloqueiosDesativados | Where-Object { $_ })) {
            Enable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
            Escreva "  Regra de bloqueio original reativada: $n" Green
        }
        Save-Estado @($estado | Where-Object { $_.Porta -ne $Porta })
    }

    # ---- 3) regras de fora do LiberaPorta que ainda deixam a porta aberta
    $aindaAberta = $false
    if ($externas) {
        Escreva "  A porta $Porta também é liberada por regra(s) do Windows que NÃO foram criadas pelo LiberaPorta:" Yellow
        foreach ($x in $externas) {
            $extra = if (@($st.RegrasPrograma | ForEach-Object { $_.Name }) -contains $x.Name) { " (regra do programa $($st.Escuta.Processo): vale para todas as portas dele)" } else { '' }
            Escreva "    - $($x.DisplayName)$extra" Yellow
        }
        $desativar = (-not $Silencioso) -and ((Read-Host '  Desativar essas regras também para fechar a porta? (S/N)') -match '^[sS]')
        if ($desativar) {
            foreach ($x in $externas) { Disable-NetFirewallRule -Name $x.Name; Write-Log "Regra externa desativada: $($x.DisplayName) [$($x.Name)]" }
            Escreva '  Regras desativadas (dá para reativar em "Firewall do Windows > Regras de Entrada").' Green
        } else { $aindaAberta = $true }
    }

    Write-Log "FECHADA porta $Porta$(if ($aindaAberta) { ' (ainda permitida por regra externa)' })"
    if ($aindaAberta) {
        Show-Faixa @(
            'O que o LiberaPorta tinha criado foi removido, mas outra regra do Windows',
            'continua permitindo esta porta.',
            '',
            "PORTA AINDA ACESSÍVEL POR OUTRA REGRA  >>>  $($ipMostrar):$Porta"
        ) 'Yellow'
    } else {
        Show-Faixa @(
            'A aplicação continua rodando no servidor, mas só localmente.',
            '',
            "PORTA FECHADA  >>>  $($ipMostrar):$Porta não está mais acessível na rede"
        ) 'Red'
    }
}

function Close-Todas {
    param([switch]$Silencioso)
    $portas = @(@(Get-Estado) | ForEach-Object { [int]$_.Porta })
    $portas += @(Get-NetFirewallRule -Group $Grupo -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^LiberaPorta-TCP-(\d+)$') { [int]$Matches[1] } })
    $portas = @($portas | Sort-Object -Unique)
    if (-not $portas) { Escreva 'Nenhuma porta liberada pelo LiberaPorta. Todas já estão fechadas.' Yellow; return }
    foreach ($p in $portas) { Escreva ''; Close-Porta -Porta $p -Silencioso:$Silencioso }
}

# =========================================================== LISTAR / DIAGN.
function Show-Lista {
    $estado = @(Get-Estado)
    if (-not $estado) { Escreva 'Nenhuma porta liberada por esta ferramenta.' Yellow; return }
    $rede = Get-RedeLocal
    $estado | Sort-Object Porta | ForEach-Object {
        $ativa = [bool](Get-NetFirewallRule -Name "LiberaPorta-TCP-$($_.Porta)" -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            Porta     = $_.Porta
            Acesso    = "$($rede.IP):$($_.Porta)"
            Tipo      = $(if ($_.Modo -eq 'Proxy') { "Redirecionada -> $($_.Destino)" } else { 'Direta' })
            Firewall  = $(if ($ativa) { 'OK' } else { 'AUSENTE' })
            Aplicacao = $_.Processo
            Desde     = $_.Data
        }
    } | Format-Table -AutoSize | Out-String | Write-Host
}

function Show-Diagnostico {
    param([int]$Porta)
    $rede = Get-RedeLocal
    Escreva "Sistema ........: $($Sistema.Edicao) $($Sistema.Versao) (build $($Sistema.Build))"
    if (-not $rede) { Escreva 'Rede ...........: nenhuma conexão ativa encontrada' Red; return }
    Escreva "Rede ...........: $($rede.Interface) | IP $($rede.IP) | perfil $($rede.Perfil)"
    $perfis = Get-NetFirewallProfile | ForEach-Object { "$($_.Name)=$(if ([string]$_.Enabled -eq 'True') { 'ligado' } else { 'desligado' })" }
    Escreva "Firewall .......: $($perfis -join ', ')"

    $st  = Get-StatusPorta -Porta $Porta -Rede $rede
    $esc = $st.Escuta
    $desc = @{
        Rede   = 'escutando na rede'
        Local4 = 'escutando SÓ em localhost IPv4 (precisa redirecionamento)'
        Local6 = 'escutando SÓ em localhost IPv6 (precisa redirecionamento)'
        Outro  = 'escutando em outro endereço'
        Nenhum = 'nenhuma aplicação escutando nesta porta'
    }[$esc.Modo]
    $quem = if ($esc.Processo) { " - programa: $($esc.Processo)" } else { '' }
    Escreva "Aplicação ......: $desc$quem"
    Escreva "Firewall porta .: $(if ($st.FirewallOk) { 'permite' } else { 'NÃO permite' })"
    Show-MotivosLiberada $st $Porta
    if ($st.PrecisaProxy) { Escreva "Redirecionamento: $(if ($st.ProxyOk) { 'ok' } else { 'FALTANDO' })" }
    if ($esc.Caminho) {
        $bloq = @(Get-BloqueiosPrograma $esc.Caminho)
        if ($bloq) { Escreva "Bloqueios ......: $($bloq.Count) regra(s) bloqueando $($esc.Processo)" Yellow }
    }
    if ($esc.Modo -ne 'Nenhum') {
        $ok = Test-Tcp $rede.IP $Porta
        Escreva "Teste local ....: $(if ($ok) { "responde em $($rede.IP):$Porta" } else { "NÃO responde em $($rede.IP):$Porta" })" $(if ($ok) { 'Green' } else { 'Yellow' })
    }

    Escreva ''
    if ($st.Liberada) {
        Escreva "STATUS: LIBERADA  >>>  $($rede.IP):$Porta" Green
        Escreva 'Se outra máquina não acessa: confirme que ela está no MESMO Wi-Fi e que o roteador' Green
        Escreva 'não tem "isolamento de clientes/AP" ligado.' Green
    } else {
        Escreva "STATUS: FECHADA  >>>  $($rede.IP):$Porta" Red
        Escreva 'Use a opção 1 (Liberar porta) para liberar.' Yellow
    }
}

function Show-Ajuda {
    Escreva 'Uso:'
    Escreva '  LiberaPorta.cmd                      abre o menu'
    Escreva '  LiberaPorta.cmd abrir 8080 5173      libera uma ou mais portas'
    Escreva '  LiberaPorta.cmd fechar 8080          fecha uma ou mais portas'
    Escreva '  LiberaPorta.cmd listar               mostra as portas liberadas'
    Escreva '  LiberaPorta.cmd diagnostico 5173     analisa uma porta'
    Escreva '  LiberaPorta.cmd fechartodas          fecha tudo que foi liberado'
}

# ======================================================================= MENU
function Read-PortaUsuario {
    param([string]$Pergunta)
    while ($true) {
        $v = Read-Host $Pergunta
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        $p = ConvertTo-Porta $v
        if ($p) { return $p }
        Escreva 'Porta inválida. Digite um número de 1 a 65535 (ou Enter para voltar).' Red
    }
}

function Show-Cabecalho {
    Clear-Host
    $rede = Get-RedeLocal
    Escreva ('=' * 64) Cyan
    Escreva "  LiberaPorta v$Versao  |  $($Sistema.Edicao) (build $($Sistema.Build))" Cyan
    if ($rede) { Escreva "  Servidor: $($rede.IP)  |  Rede: $($rede.Interface) ($($rede.Perfil))" Cyan }
    else { Escreva '  Servidor: SEM REDE ATIVA' Red }
    $abertas = @(@(Get-Estado) | ForEach-Object { $_.Porta } | Sort-Object)
    Escreva "  Portas liberadas pelo LiberaPorta: $(if ($abertas) { $abertas -join ', ' } else { 'nenhuma' })" Cyan
    Escreva ('=' * 64) Cyan
    Escreva ''
}

function Start-Menu {
    while ($true) {
        Show-Cabecalho
        Escreva '  1. Liberar porta'
        Escreva '  2. Fechar porta'
        Escreva '  3. Listar portas liberadas'
        Escreva '  4. Diagnosticar porta'
        Escreva '  5. Fechar TODAS as portas liberadas'
        Escreva '  0. Sair'
        Escreva ''
        $op = (Read-Host 'Escolha uma opção').Trim()
        Escreva ''
        try {
            switch ($op) {
                '1' { $p = Read-PortaUsuario 'Informe o número da porta que deseja LIBERAR (1 a 65535)'; if ($p) { Open-Porta -Porta $p } }
                '2' { $p = Read-PortaUsuario 'Informe o número da porta que deseja FECHAR (1 a 65535)'; if ($p) { Close-Porta -Porta $p } }
                '3' { Show-Lista }
                '4' { $p = Read-PortaUsuario 'Informe o número da porta que deseja DIAGNOSTICAR (1 a 65535)'; if ($p) { Show-Diagnostico -Porta $p } }
                '5' { if ((Read-Host 'Fechar TODAS as portas liberadas? (S/N)') -match '^[sS]') { Close-Todas } }
                '0' { return }
                default { Escreva 'Opção inválida.' Red }
            }
        } catch {
            Escreva "ERRO: $($_.Exception.Message)" Red
            Write-Log "ERRO: $($_.Exception.Message)"
        }
        Escreva ''
        Read-Host 'Pressione Enter para voltar ao menu' | Out-Null
    }
}

function Invoke-Linha {
    $cmd = $Argumentos[0].ToLower()
    $portas = @($Argumentos | Select-Object -Skip 1 | ForEach-Object {
        $p = ConvertTo-Porta $_
        if (-not $p) { throw "Porta inválida: $_" }
        $p
    })
    switch -Regex ($cmd) {
        '^(abrir|liberar|open)$' {
            if (-not $portas) { throw 'Informe a porta. Ex.: LiberaPorta.cmd abrir 8080' }
            foreach ($p in $portas) { Open-Porta -Porta $p -Silencioso }
        }
        '^(fechar|close)$' {
            if (-not $portas) { throw 'Informe a porta. Ex.: LiberaPorta.cmd fechar 8080' }
            foreach ($p in $portas) { Close-Porta -Porta $p -Silencioso }
        }
        '^(listar|list)$'            { Show-Lista }
        '^(diagnostico|diag)$'       { foreach ($p in $portas) { Show-Diagnostico -Porta $p } }
        '^(fechartodas|closeall)$'   { Close-Todas -Silencioso }
        '^(ajuda|help|/\?|-h)$'      { Show-Ajuda }
        default { Show-Ajuda; throw "Comando desconhecido: $cmd" }
    }
}

# ===================================================================== INÍCIO
$codigo = 0
try {
    $Sistema = Get-InfoSistema
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        throw 'Os comandos de firewall do Windows (módulo NetSecurity) não estão disponíveis.'
    }
    $mudouIP = Sync-IP
    if ($Argumentos.Count -gt 0) { Invoke-Linha }
    else {
        if ($mudouIP) { Read-Host 'Pressione Enter para abrir o menu' | Out-Null }
        Start-Menu
    }
} catch {
    Escreva "ERRO: $($_.Exception.Message)" Red
    Write-Log "ERRO: $($_.Exception.Message)"
    $codigo = 1
}
if ($Elevado -and $Argumentos.Count -gt 0) { Read-Host 'Pressione Enter para fechar' | Out-Null }
exit $codigo
