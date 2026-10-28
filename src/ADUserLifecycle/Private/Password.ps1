# Conjuntos sin caracteres ambiguos (0/O, 1/l/I) para que la contraseña se pueda dictar por teléfono.
$script:PasswordCharsets = @(
    'ABCDEFGHJKLMNPQRSTUVWXYZ',
    'abcdefghijkmnopqrstuvwxyz',
    '23456789',
    '!#$%*+-=?@_'
)

function Get-LifecycleRandomInt {
    <#
    .SYNOPSIS
    Entero aleatorio en [0, MaxExclusive) con RNG criptográfico y sin sesgo de módulo.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [ValidateRange(1, 65536)] [int] $MaxExclusive)

    $bytes = New-Object byte[] 4
    $range = [long][uint32]::MaxValue + 1
    $limit = $range - ($range % $MaxExclusive)
    do {
        $script:Rng.GetBytes($bytes)
        $value = [long][System.BitConverter]::ToUInt32($bytes, 0)
    } while ($value -ge $limit)
    return [int]($value % $MaxExclusive)
}

function Test-LifecyclePasswordComplexity {
    <#
    .SYNOPSIS
    Valida la política: largo mínimo, mayúscula, minúscula, número y símbolo, y que no
    contenga el usuario ni partes del nombre (misma regla que aplica AD).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Candidate,
        [int] $MinLength = 14,
        [string] $SamAccountName,
        [string] $DisplayName
    )

    if ($Candidate.Length -lt $MinLength) { return $false }
    if ($Candidate -cnotmatch '[A-Z]') { return $false }
    if ($Candidate -cnotmatch '[a-z]') { return $false }
    if ($Candidate -notmatch '[0-9]') { return $false }
    if ($Candidate -notmatch '[^A-Za-z0-9]') { return $false }

    if ($SamAccountName -and $SamAccountName.Length -ge 3 -and
        $Candidate.IndexOf($SamAccountName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $false
    }
    if ($DisplayName) {
        foreach ($token in ($DisplayName -split '[\s,.\-_#]+')) {
            if ($token.Length -ge 3 -and $Candidate.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $false
            }
        }
    }
    return $true
}

function New-LifecyclePasswordText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Solo genera un valor en memoria.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(14, 128)] [int] $Length = 16,
        [string] $SamAccountName,
        [string] $DisplayName
    )

    $all = -join $script:PasswordCharsets
    do {
        $chars = New-Object 'System.Collections.Generic.List[char]'
        foreach ($set in $script:PasswordCharsets) {
            $chars.Add($set[(Get-LifecycleRandomInt -MaxExclusive $set.Length)])
        }
        while ($chars.Count -lt $Length) {
            $chars.Add($all[(Get-LifecycleRandomInt -MaxExclusive $all.Length)])
        }
        # Fisher-Yates para que los caracteres obligatorios no queden siempre al principio.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = Get-LifecycleRandomInt -MaxExclusive ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        $candidate = -join $chars
    } until (Test-LifecyclePasswordComplexity -Candidate $candidate -MinLength $Length -SamAccountName $SamAccountName -DisplayName $DisplayName)

    return $candidate
}

function New-LifecyclePassword {
    <#
    .SYNOPSIS
    Genera una contraseña temporal que cumple la política y la devuelve como SecureString.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Solo genera un valor en memoria.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [ValidateRange(14, 128)] [int] $Length = 16,
        [string] $SamAccountName,
        [string] $DisplayName
    )

    $text = New-LifecyclePasswordText -Length $Length -SamAccountName $SamAccountName -DisplayName $DisplayName
    return (ConvertTo-LifecycleSecureString -Text $text)
}
