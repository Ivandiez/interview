[CmdletBinding()]
param (
    [Parameter(Mandatory=$True)]
    [string]$environment,
    
    [Parameter(Mandatory=$True)]
    [string]$podName,

    [Parameter(Mandatory=$True)]
    [string]$esHost,

    [Parameter(Mandatory=$True)]
    [string]$esHostRestore,

    [Parameter(Mandatory=$True)]
    [string]$backendType,

    [Parameter(Mandatory=$True)]
    [ValidatePattern("\d{4}-\d+-\d+_\d+$")]
    [string]$snapshotDate,
    
    [Int]$countOfFiles = 3
)

class SnapshotInfo 
{
    [string]$id
    [string]$status
}

function GetDatesForBackups (
    [string]$dateOfSnapshot) 
{
    $datesList = [System.Collections.ArrayList]@();
    $splitDateTime = $dateOfSnapshot -split('_')

    $date = $splitDateTime[0]
    $time = $splitDateTime[1]

    $splitDate = $date -split('-')
    $splitTime = $time -split('-')

    $year = $splitDate[0]
    $month = $splitDate[1]
    $day = $splitDate[2]
    $hour = $splitTime[0]
    
    for ($i = 0; $i -lt $countOfFiles; $i++) 
    {
        $dateTime = Get-Date -Date ((Get-Date -Year $year -Month $month -Day $day -Hour $hour).AddHours(-$i)) -Format "yyyy-MM-dd_H"
        $datesList.Add($dateTime) | Out-Null
    }

    return $datesList
}

function GetAllSnapshotsFromRepository(
    [string]$directoryColor) 
{
    try 
    {
        Write-Host "Trying to get snapshots from $($directoryColor.ToUpper()) repository...`n"

        $allSnapshots = [SnapshotInfo[]](Invoke-RestMethod "http://$($esHost):9200/_cat/snapshots/snapshots_$($directoryColor)_$($backendType)?h=id,status" -Headers @{"accept"="application/json"})

        Write-Host "Successfully finished got snapshots from $($directoryColor.ToUpper()) repository!" -ForegroundColor Green;
    }
    catch 
    {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    Write-Host ""

    return $allSnapshots
}

function CreateListOfNeededSnapshots(
    [SnapshotInfo[]]$listOfSnapshots,
    [System.Collections.ArrayList]$snapshotsDateList)
{
    $snapshotsForRestore = [System.Collections.ArrayList]@();

    for ($i = 0; $i -lt $listOfSnapshots.count; $i++)
    {
        foreach ($snapDate in $snapshotsDateList) 
        {
            if (($listOfSnapshots[$i].status -eq "SUCCESS") -and ($listOfSnapshots[$i].id | Select-String -Pattern "$($snapDate)-"))
            {
                $snapshotsForRestore.Add($listOfSnapshots[$i].id) | Out-Null
            }
        }
    }

    return $snapshotsForRestore
}

function SelectSnapshotName (
    [System.Collections.Hashtable]$selectedSnapshots,
    [string]$directoryColor)
{
    if ($selectedSnapshots[$directoryColor])
    {
        $i = 1
        if ($selectedSnapshots[$directoryColor].Count -gt 1)
        {
            foreach ($selectedSnapshot in $selectedSnapshots[$directoryColor])
            {
                Write-Host $i - $selectedSnapshot
                $i++
            }
            $numberOfSnapshot = Read-Host "Enter the number of snapshot to restore"

            $snapshotForRestore = $selectedSnapshots[$directoryColor][($numberOfSnapshot - 1)]
        }
        else
        {
            Write-Host 1 - $selectedSnapshots[$directoryColor]

            $numberOfSnapshot = Read-Host "Enter the number of snapshot to restore"

            $snapshotForRestore = $selectedSnapshots[$directoryColor]
        }
       
        Write-Host "You choose $($snapshotForRestore)`n"

        return $snapshotForRestore
    }

    return
}

function GetESClusterName 
{
    Write-Host "Trying to get cluster name...`n"
    
    $clusterName = (Invoke-RestMethod "http://$($esHost):9200/_cluster/health").cluster_name
    
    Write-Host "Cluster name is $($clusterName)`n"

    return $clusterName
}


function DeleteAllIndexesBeforeRestore(
    [string]$deleteType)
{
    try
    {  
        if ($deleteType -eq "all")
        {
            Write-Host "Trying to delete all indexes from new cluster before restore...`n"
            iwr -Method Delete -Uri "http://$($esHostRestore):9200/_all" -UseBasicParsing

                    
            Start-Sleep -Seconds 5
            Write-Host "All indexes successfully deleted from new cluster!`n"
        }
        elseif ($deleteType -eq "kibana")
        {
            Write-Host "Trying to delete .kibana indexes from new cluster before restore...`n"
            iwr -Method Delete -Uri "http://$($esHostRestore):9200/.kibana*" -UseBasicParsing

            Start-Sleep -Seconds 2
            Write-Host ".kibana* indexes successfully deleted from new cluster!`n"
        }
        else 
        {
            return
        }
        
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    
}

function CreateESRepository(
    [string]$clusterName,
    [string]$bucketName,
    [string]$directoryColor)
{
    if ($backendType -eq "azure")
    {
        $repositorySettings = @{
            "container" = "backups";
            "base_path" = "$($clusterName)/$($directoryColor)";
            "compress" = "true"
        }
    }
    else 
    {
        $repositorySettings = @{
            "bucket" = "$($bucketName)";
            "base_path" = "backups/$($clusterName)/$($directoryColor)";
            "compress" = "true"
        }    
    }
    

    $repositoryBody = @{
        "type" = "$($backendType)";
        "settings" = $repositorySettings
    }

    Write-Host "Trying to create repository for restore snapshot"
    
    iwr -Method Put "http://$($esHostRestore):9200/_snapshot/snapshot_$($backendType)" -ContentType "application/json" -Body (ConvertTo-Json $repositoryBody) -UseBasicParsing
    
    Write-Host "Repository snapshot_$($backendType) successfully created!`n" 
}
    
Function RunRestoreRequest (
    [string]$selectedSnapshot)
{
    $body = @{
        "include_global_state" = "true"
    }

    Write-Host "Trying to Send request for restore Elasticsearch cluster from selected snapshot..."
    
    iwr -Method Post -Uri "http://$($esHostRestore):9200/_snapshot/snapshot_$($backendType)/$($selectedSnapshot)/_restore?wait_for_completion=false" -Body (ConvertTo-Json $body) -ContentType "application/json" -UseBasicParsing
    
    Write-Host "Request for create snapshot successfully sent!" -ForegroundColor green;
    Write-Host "`nScript for restore ES cluster finished!" -ForegroundColor Green;

    exit
}

function RestoreProcess (
    [System.Collections.ArrayList]$snapshotsDateList,
    [string]$clusterName,
    [string]$bucketName,
    [System.Collections.Hashtable]$selectedSnapshots,
    [string]$directoryColor)
{
    $listOfAllSnapshots = GetAllSnapshotsFromRepository $directoryColor
    $listOfNeededSnapshots = CreateListOfNeededSnapshots $listOfAllSnapshots $snapshotsDateList
    $selectedSnapshots.Add($directoryColor, $listOfNeededSnapshots)
    Write-Host $selectedSnapshots[$directoryColor]
    $selectedSnapshot = SelectSnapshotName $selectedSnapshots $directoryColor
    
    if ($selectedSnapshot)
    {
        $deleteType = Read-Host -Prompt "Please, enter what indexes to delete before restore ('all', 'kibana' or 'no')"
        DeleteAllIndexesBeforeRestore $deleteType
        CreateESRepository $clusterName $bucketName $directoryColor
        RunRestoreRequest $selectedSnapshot
    }
}

function RestoreCluster {
    Write-Host ""
    Write-Host "`nScript for restore ES cluster started" -ForegroundColor Green;
    Write-Host ""

    $snapshotsDateList = GetDatesForBackups $snapshotDate
    $clusterName = GetESClusterName
    $selectedSnapshots = @{};

    if ($backendType -eq "s3")
    {
        $bucketName = Read-Host -Prompt "Please, enter S3 Bucket name"
    }
    else 
    {
        $bucketName = ""
    }

    RestoreProcess $snapshotsDateList $clusterName $bucketName $selectedSnapshots "green"
    RestoreProcess $snapshotsDateList $clusterName $bucketName $selectedSnapshots "blue"
}

RestoreCluster