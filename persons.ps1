##################################################
# HelloID-Conn-Prov-Source-Intus-Inplanning-Persons
#
# Version: 1.2.0
##################################################

# Sleep is added because the department script needs to finish first (invalid token messages can occur otherwise)
Start-Sleep -Seconds 30 

# Initialize default value's
$config = $configuration | ConvertFrom-Json
$useUserEndpoint = $true
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
    $actionMessage = "retrieving users"

    if ($useUserEndpoint -eq $true) {
        $splatGetUsers = @{
            Uri = "$($Script:BaseUrl)/users?limit=0"
        }
        $persons = Invoke-IntusInplanningRestMethod @splatGetUsers
        Write-Information "Total number of persons retrieved: $($persons.count)."
        $persons = $persons | Where-Object active -eq "True"
        $persons = $persons | Sort-Object resource -Unique
        Write-Information "Total number of active persons retrieved: $($persons.count)."
    }
    else {
        $splatGetUsers = @{
            Uri = "$($Script:BaseUrl)/humanresources?limit=0"
        }  
        $persons = Invoke-IntusInplanningRestMethod @splatGetUsers
        Write-Information "Total number of humanresources retrieved: $($persons.count)."
        $persons | Add-Member -MemberType NoteProperty -Name "resource" -Value $null -Force
        $persons = $persons | ForEach-Object { $_.resource = $_.uname; $_ }
        # Filter out persons where all labourHists have startDate in future or endDate in past
        $persons = $persons | Where-Object {
            $person = $_
            $today = Get-Date
            $hasValidLabourHist = $person.labourHists | Where-Object {
                $startDate = if ($_.startDate) { [DateTime]$_.startDate } else { $null }
                $endDate = if ($_.endDate) { [DateTime]$_.endDate } else { $null }
            
                $isValid = $true
                if ($startDate -and $startDate -gt $today) { $isValid = $false }
                if ($null -ne $endDate -and $endDate -lt $today) { $isValid = $false }
            
                $isValid
            }
            $null -ne $hasValidLabourHist
        }
        $persons = $persons | Select-Object -Property uname, externalId, resource, firstName, lastName, gender, phone, email
        $persons = $persons | Sort-Object uname -Unique
        write-information "Total number of active humanresources retrieved: $($persons.count)."

        # Example how to use the externalId from humanresources when it is used. Part [1/2]
        # foreach ($person in $persons) {
        #     # Custom checking if person has externalId and filtering persons without a numbers as externalId or uname
        #     if (-not [string]::IsNullOrEmpty($person.externalId)) {
        #         $person.resource = $person.externalId
        #     }
        # }
        # 
    } 

    $actionMessage = "retrieving resource groups"
    $splatGetResourceGroups = @{
        Uri = "$($Script:BaseUrl)/v2/resourcegroups"
    }
    $resourceGroupsResponse = Invoke-IntusInplanningRestMethod @splatGetResourceGroups
    $resourceGroups = $resourceGroupsResponse | Sort-Object uname -Unique
    $resourceGroupsGrouped = $resourceGroups | Group-Object -Property uname -AsHashTable
    write-information "Total number of unique resource groups retrieved: $($resourceGroups.count)."

    $today = Get-Date
    $startDate = $today.AddDays( - $($config.HistoricalDays)).ToString('yyyy-MM-dd')
    $endDate = $today.AddDays($($config.FutureDays)).ToString('yyyy-MM-dd')

    foreach ($person in $persons) {
        $actionMessage = "retrieving roster date for person [$($person.resource)]"
        if (-not([string]::IsNullOrEmpty($person.resource))) { 
            $contracts = [System.Collections.Generic.List[object]]::new()

            #resource can contain special characters
            $personResource = $([System.Web.HttpUtility]::UrlEncode($person.resource))
            # Example how to use the externalId from humanresources when it is used. Part [2/2]
            # $personResource = $([System.Web.HttpUtility]::UrlEncode($person.uname))
            $splatGetUsersShifts = @{
                Uri = "$($Script:BaseUrl)/roster/resourceRoster?resource=$($personResource)&startDate=$($startDate)&endDate=$($endDate)"
            }

            [array]$personShifts = Invoke-IntusInplanningRestMethod @splatGetUsersShifts

            If ($personShifts.count -gt 0) {
                foreach ($day in $personShifts.days) {
                    # Reset counter to keep external ID after each day the same
                    $counter = 0

                    # Removes days when person has vacation
                    if ((-not($day.parts.count -eq 0)) -and ($null -eq $day.absence)) {

                        $rosterDate = $day.rosterDate
                        
                        foreach ($part in $day.parts) {
                            $counter = $counter + 1
                            $externalId = "$($person.resource)-$($rosterDate)-$($counter)"
                            
                            if ($part.shift.uname -like '*:*') {
                                # Define the pattern for hh:mm-hh:mm
                                $pattern = '^\d{2}:\d{2}-\d{2}:\d{2}'
                                $time = [regex]::Match($part.shift.uname, $pattern)
                                if ($time.Success) {
                                    $times = $time.value -split '-'
                                    $startTime = $times[0]
                                    $endTime = $times[1]
                                }
                                else {
                                    $startTime = '00:00'
                                    $endTime = '00:00'
                                }
                            }
                            else {
                                # Define the pattern for hhmm-hhmm
                                $pattern = '^\d{4}-\d{4}'
                                $time = [regex]::Match($part.shift.uname, $pattern)
                                if ($time.Success) {
                                    $times = $time.value -split '-'
                                    $startTimeUnformatted = $times[0]
                                    $endTimeUnformatted = $times[1]
                                    # Format HHMM to HH:MM
                                    $startTime = "$($startTimeUnformatted.Substring(0, 2)):$($startTimeUnformatted.Substring(2, 2))"
                                    $endTime = "$($endTimeUnformatted.Substring(0, 2)):$($endTimeUnformatted.Substring(2, 2))"
                                }
                                else {
                                    $startTime = '00:00'
                                    $endTime = '00:00'
                                }
                            }

                            if ($part.prop) {
                                $functioncode = $part.prop.uname
                                $function = $part.prop.name
                            }
                            else {
                                $functioncode = ""
                                $function = ""
                                # break # If you want to skip shifts without a function, you can uncomment this line.
                            }

                            $groupExternalId = $part.group.externalId
                            if (-not [string]::IsNullOrEmpty($groupExternalId)) {
                                $partentGroup = $resourceGroupsGrouped[$groupExternalId].parent
                            }

                            $ShiftContract = @{
                                externalId      = $externalId 
                                labourHist      = $part.labourHist
                                labourHistGroup = $part.labourHistGroup
                                shift           = $part.shift
                                group           = $part.group
                                parentGroup     = $partentGroup
                                functioncode    = $functioncode
                                functionname    = $function
                                # Add the same fields as for shift. Otherwise, the HelloID mapping will fail
                                # The value of both the 'startAt' and 'endAt' cannot be null. If empty, HelloID is unable
                                # to determine the start/end date, resulting in the contract marked as 'active'.
                                startAt         = "$($rosterDate)T$($startTime):00Z"
                                endAt           = "$($rosterDate)T$($endTime):00Z"
                            }

                            $contracts.Add($ShiftContract)
                        }
                    }
                }

                if ($contracts.Count -gt 0) {
                    $personObj = [PSCustomObject]@{
                        ExternalId  = $person.resource
                        DisplayName = "$($person.firstName) $($person.lastName)".Trim(' ') + " ($($person.resource))"
                        FirstName   = $person.firstName
                        LastName    = $person.lastName
                        Email       = $person.email
                        Contracts   = $contracts
                    }
                    Write-Output $personObj | ConvertTo-Json -Depth 10
                    $count++
                }
            }
        }
    }
    Write-Information "Total number of persons processed: $count."
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