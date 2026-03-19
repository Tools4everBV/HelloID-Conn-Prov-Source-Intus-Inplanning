##################################################
# HelloID-Conn-Prov-Source-Intus-Inplanning-Departments
#
# Version: 1.1.0
##################################################

# Initialize default value's
$config = $configuration | ConvertFrom-Json
$Script:expirationTimeAccessToken = $null
$Script:AuthenticationHeaders = $null
$Script:BaseUrl = $config.BaseUrl
$Script:Username = $config.Username
$Script:Password = $config.Password

#region functions
function Resolve-IntusInplanningError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }

        try {
            $errorMessage = (($ErrorObject.ErrorDetails.Message | ConvertFrom-Json))
            $httpErrorObj.FriendlyMessage = $errorMessage.error_description
            $httpErrorObj.ErrorDetails = $errorMessage.error
        }
        catch {
            # If the error details cannot be parsed as JSON, we keep the original message as both the error details and friendly message.
        }
        Write-Output $httpErrorObj
    }
}

function Retrieve-AccessToken {
    [CmdletBinding()]
    param()
    try {
        $pair = "$($Username):$($Password)"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
        $base64 = [System.Convert]::ToBase64String($bytes)
        $tokenHeaders = @{
            'Content-Type' = 'application/x-www-form-urlencoded'
            Authorization  = "Basic $base64"
        }
        $splatGetToken = @{
            Uri     = "$($BaseUrl)/token"
            Headers = $tokenHeaders
            Method  = 'POST'
            Body    = 'grant_type=client_credentials'
        }

        $retryCount = 0
        $maxRetries = 5
        do {
            try {
                $access_token = (Invoke-RestMethod @splatGetToken)
                break
            }
            catch {
                $retryCount++
                $ex = $PSItem
                $errorObj = Resolve-IntusInplanningError -ErrorObject $ex
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Write-Warning "Error during API call. Retry attempt [$retryCount] of [$maxRetries]. Uri [$($splatGetToken.Uri)] Error: [$($errorObj.ErrorDetails)] [$($errorObj.FriendlyMessage)]"
                    Start-Sleep -Seconds 5
                }
                else {
                    throw $ex
                }
            }
        } while ($retryCount -lt $maxRetries)

        $Script:expirationTimeAccessToken = (Get-Date).AddSeconds($access_token.expires_in)
        return $access_token.access_token
    } 
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Confirm-AccessTokenIsValid {
    [CmdletBinding()]
    param()
    try {
        if ($null -ne $Script:expirationTimeAccessToken) {
            if ((Get-Date) -le $Script:expirationTimeAccessToken) {
                return $true
            }
            write-warning "Access token is no longer valid. Expiration time: $($Script:expirationTimeAccessToken)"
        }
        return $false
    } 
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Invoke-IntusInplanningRestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $Uri
    )

    try {
        # Check if token is still valid
        $tokenValid = Confirm-AccessTokenIsValid
        if ($false -eq $tokenValid) {
            Start-Sleep -Seconds 5 # Wait 5 seconds before trying to retrieve a new token.
            $newAccessToken = Retrieve-AccessToken
            $Script:AuthenticationHeaders = @{
                Authorization = "Bearer $($newAccessToken)"
                Accept        = 'application/json; charset=utf-8'
            }
            Start-Sleep -Seconds 5 # Wait 5 seconds after trying to retrieve a new token.
        }

        # Execute with retry logic
        $retryCount = 0
        $maxRetries = 5
        $result = $null

        $SplatRestMethodParameters = @{
            Uri     = $Uri
            Headers = $Script:AuthenticationHeaders
            Method  = 'GET'
        }

        do {
            try {
                $result = Invoke-RestMethod @SplatRestMethodParameters
                break
            }
            catch {
                $ex = $PSItem
                $errorObj = Resolve-IntusInplanningError -ErrorObject $ex
                if ($ex.ErrorDetails.Message -like '*211 - resource: The item you\u0027re trying to edit does not exist.*') {
                    Write-Warning "Resource does not exist: $Uri"
                    break
                }
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    if (($errorObj.ErrorDetails -eq 'invalid_token') -or ($errorObj.ErrorDetails -eq 'token_expired')) {
                        Start-Sleep -Seconds 5 # Wait 5 seconds before trying to retrieve a new token.
                        Write-Warning "Access token is [$($errorObj.ErrorDetails)] [$($errorObj.FriendlyMessage)]. Attempting to retrieve a new access token. Retry attempt $retryCount of $maxRetries."
                        $newAccessToken = Retrieve-AccessToken
                        $Script:AuthenticationHeaders = @{
                            Authorization = "Bearer $($newAccessToken)"
                            Accept        = 'application/json; charset=utf-8'
                        }
                        $SplatRestMethodParameters.Headers = $Script:AuthenticationHeaders
                        Start-Sleep -Seconds 5 # Wait 5 seconds after trying to retrieve a new token.
                    }
                    else {
                        Write-Warning "Error during API call. Retry attempt [$retryCount] of [$maxRetries]. Uri [$($SplatRestMethodParameters.Uri)] Error: [$($errorObj.ErrorDetails)] [$($errorObj.FriendlyMessage)]"
                    }
                    Start-Sleep -Milliseconds 500
                }
                else {
                    throw $ex
                }
            }
        } while ($retryCount -lt $maxRetries)

        return $result
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion functions

try {
    $actionMessage = "retrieving resource groups"
    $splatGetResourceGroups = @{
        Uri = "$($Script:BaseUrl)/v2/resourcegroups"
    }
    $resourceGroupsResponse = Invoke-IntusInplanningRestMethod @splatGetResourceGroups
    $resourceGroups = $resourceGroupsResponse | Sort-Object uname -Unique
    write-information "Total number of unique resource groups retrieved: $($resourceGroups.count)."

    foreach ($resource in $resourceGroups) {
        $departmentObject = [PSCustomObject]@{
            ExternalId        = $resource.uname
            DisplayName       = $resource.name
            ManagerExternalId = $null
            ParentExternalId  = $resource.parent
        }
        Write-Output $departmentObject | ConvertTo-Json -Depth 10
    }
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-IntusInplanningError -ErrorObject $ex
        Write-Warning "Error while $actionMessage. Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Error while $actionMessage. Error: $($errorObj.FriendlyMessage)"
    }
    else {
        Write-Warning "Error while $actionMessage. Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Error while $actionMessage. Error: $($ex.Exception.Message)"
    }
}