/*
    IPS Quartz Sink Backburner Submission (Production-Safe)
    ------------------------------------------------------
    Purpose:
    - Process ONLY the currently open scene (no scene-file opening).
    - Find sinks by exact SKU node name.
    - Enforce visibility (hide all sinks, show only current sink).
    - Apply quartz finish materials.
    - Set camera/output state and submit EACH render to Backburner.

    Reliability note:
    - By default, each job is submitted from a TEMP saved scene file to prevent
      queued jobs from inheriting later scene changes.
    - This is intentionally safer for large queue submissions.
*/

/* =========================
   USER-EDITABLE SETTINGS
   ========================= */
global OUTPUT_ROOT        = @"R:\Aidan\IPS"
global QUARTZ_MATLIB      = @"R:\Creative\3D Library\3D Library\Material Library\Quartz.mat"
global RENDER_WIDTH       = 2000
global RENDER_HEIGHT      = 2000
global JPG_QUALITY        = 100

global BACKBURNER_MANAGER = "10.10.0.59"
global BACKBURNER_PORT    = 3234 -- default Backburner port
global TEMP_SCENE_FOLDER  = @"R:\Aidan\IPS\_TempScenes"
global DRY_RUN            = false
global USE_TEMP_SCENE_PER_JOB = true
global SUBMISSION_STABILIZE_MS = 250

/* =========================
   HARDCODED TABLES
   ========================= */

global FINISHES = #(
    #("WH", "White_Quartz"),
    #("BL", "Black_Quartz"),
    #("CN", "Concrete_Quartz_02"),
    #("GR", "Grey_Quartz_02"),
    #("BI", "Bisque_Quartz_02"),
    #("BR", "Brown_Quartz_02")
)

global SIZE_SMALL  = #( "QT-825", "QU-690", "Q-315", "Q-306", "Q-309" )
global SIZE_MEDIUM = #( "Q-320" )
global SIZE_LARGE  = #(
    "Q-340", "QU-670", "QU-610", "QU-711", "QU-712", "Q-360R", "QU-710", "QUWS-875", "Q-350",
    "QT-610", "QT-670", "QT-710", "QT-711", "QT-712", "QTWS-875", "QTWS-880", "QUWS-880",
    "QA-740", "QA-750", "QA-760", "QAR-740", "QAR-750", "QAR-760", "QARWS-740", "QAWS-740"
)

global CAMERAS_SMALL  = #( "Corona Camera001", "Corona Camera002", "Corona Camera003", "Corona Camera004" )
global CAMERAS_MEDIUM = #( "Corona Camera005", "Corona Camera006", "Corona Camera007", "Corona Camera008" )
global CAMERAS_LARGE  = #( "Corona Camera009", "Corona Camera010", "Corona Camera011", "Corona Camera012" )

global VALID_SINK_PREFIXES = #( "QARWS", "QAWS", "QUWS", "QTWS", "QAR", "QA", "QU", "QT", "Q" )

global IPS_LogFilePath = undefined

/* =========================
   LOGGING
   ========================= */

fn ips_timeStamp =
(
    local d = localTime
    (formattedPrint d.year format:"04d") + "-" +
    (formattedPrint d.month format:"02d") + "-" +
    (formattedPrint d.day format:"02d") + " " +
    (formattedPrint d.hour format:"02d") + ":" +
    (formattedPrint d.minute format:"02d") + ":" +
    (formattedPrint d.second format:"02d")
)

fn ips_safeMakeDir path =
(
    if path == undefined or path == "" then return false
    if doesDirectoryExist path then return true
    makeDir path
)

fn ips_initLogFile =
(
    if ips_safeMakeDir OUTPUT_ROOT then
    (
        IPS_LogFilePath = OUTPUT_ROOT + "\\IPS_Backburner_Log_" + substituteString (ips_timeStamp()) ":" "-" + ".txt"
        try
        (
            local f = createFile IPS_LogFilePath
            format "IPS Quartz Backburner Log\n" to:f
            close f
        )
        catch (IPS_LogFilePath = undefined)
    )
)

fn ips_log msg =
(
    local line = "[" + ips_timeStamp() + "] " + msg
    format "%\n" line

    if IPS_LogFilePath != undefined then
    (
        try
        (
            local f = openFile IPS_LogFilePath mode:"a"
            format "%\n" line to:f
            close f
        )
        catch()
    )
)

/* =========================
   HELPERS
   ========================= */

fn ips_startsWithAny source prefixes =
(
    if source == undefined then return false
    local upperName = toUpper source
    for p in prefixes do
    (
        local pUpper = toUpper p
        if matchPattern upperName pattern:(pUpper + "*") ignoreCase:true do return true
    )
    false
)

fn isSinkNodeName nodeName =
(
    ips_startsWithAny nodeName VALID_SINK_PREFIXES
)

fn collectAllSinkNodes =
(
    local sinks = #()
    for o in geometry do
    (
        if isValidNode o and isSinkNodeName o.name then append sinks o
    )
    sinks
)

fn hideAllSinks sinkNodes =
(
    for n in sinkNodes where isValidNode n do
    (
        try (n.isHidden = true) catch()
    )
)

fn getSizeGroup sku =
(
    if findItem SIZE_SMALL sku > 0 then return "SMALL"
    if findItem SIZE_MEDIUM sku > 0 then return "MEDIUM"
    if findItem SIZE_LARGE sku > 0 then return "LARGE"
    undefined
)

fn getCamerasForSizeGroup sizeGroup =
(
    case sizeGroup of
    (
        "SMALL": CAMERAS_SMALL
        "MEDIUM": CAMERAS_MEDIUM
        "LARGE": CAMERAS_LARGE
        default: undefined
    )
)

fn getNodeByExactName nodeName =
(
    getNodeByName nodeName exact:true ignoreCase:false
)

fn verifyCameraNodes cameraNames =
(
    local cameraNodes = #()
    local missing = #()

    for cName in cameraNames do
    (
        local c = getNodeByExactName cName
        if c == undefined then append missing cName else append cameraNodes c
    )

    #(cameraNodes, missing)
)

fn arrayToCommaString arr =
(
    local s = ""
    for i = 1 to arr.count do
    (
        s += arr[i]
        if i < arr.count then s += ", "
    )
    s
)

fn buildOutputFilePath sku finishCode ipsIndex =
(
    local idxStr = formattedPrint ipsIndex format:"02d"
    local fileName = sku + "_" + finishCode + "_IPS" + idxStr + ".jpg"
    OUTPUT_ROOT + "\\" + sku + "\\" + fileName
)

fn ensureSkuOutputFolder sku =
(
    local dir = OUTPUT_ROOT + "\\" + sku
    if doesDirectoryExist dir then return true
    makeDir dir
)

fn ensureTempFolder =
(
    if not USE_TEMP_SCENE_PER_JOB then return true
    ips_safeMakeDir TEMP_SCENE_FOLDER
)

fn loadQuartzMaterialByName matLibPath matName =
(
    if not doesFileExist matLibPath then return undefined

    local ml = undefined
    try (ml = loadTempMaterialLibrary matLibPath) catch (ml = undefined)
    if ml == undefined then return undefined

    for i = 1 to ml.count do
    (
        local m = ml[i]
        if m != undefined and (toUpper m.name == toUpper matName) then return m
    )
    undefined
)

fn setJpgOutputQuality quality =
(
    try (renderers.current.output_jpeg_quality = quality) catch()
    try (JPEGIO.setQuality quality) catch()
)

fn setRenderStateForSubmission camNode outputPath width height =
(
    try (rendOutputFilename = outputPath) catch()
    try (rendSaveFile = true) catch()
    try (rendImageAspect = 1.0) catch()
    try (renderWidth = width) catch()
    try (renderHeight = height) catch()
    try (rendUseActiveView = false) catch()
    try (rendCamNode = camNode) catch()
    try (viewport.setCamera camNode) catch()

    setJpgOutputQuality JPG_QUALITY
    completeRedraw()
    sleep (SUBMISSION_STABILIZE_MS / 1000.0)
)

fn buildTempScenePath jobName =
(
    TEMP_SCENE_FOLDER + "\\" + jobName + ".max"
)

fn saveTempSceneSnapshot tempScenePath =
(
    if DRY_RUN then return true

    local ok = false
    try
    (
        -- save selected job state to isolated scene file for reliable queueing
        saveMaxFile tempScenePath clearNeedSaveFlag:true useNewFile:false quiet:true
        ok = doesFileExist tempScenePath
    )
    catch (ok = false)
    ok
)

fn escapeForExecute s =
(
    substituteString s "\\" "\\\\"
)

fn submitViaNetRender tempScenePath jobName managerIP managerPort =
(
    if DRY_RUN then return true

    local submitted = false

    -- Best-effort compatibility across Max versions: try several known call patterns.
    try
    (
        execute ("if (isProperty netrender #manager) do (netrender.manager = \"" + managerIP + "\")")
    ) catch()

    try
    (
        execute ("if (isProperty netrender #port) do (netrender.port = " + (managerPort as string) + ")")
    ) catch()

    -- Attempt 1
    try
    (
        local cmd = "netrender.submitJob @\"" + tempScenePath + "\" jobName:@\"" + jobName + "\""
        submitted = execute cmd
    ) catch()

    -- Attempt 2
    if not submitted then
    (
        try
        (
            local cmd2 = "netrender.submit @\"" + tempScenePath + "\" @\"" + jobName + "\""
            local r2 = execute cmd2
            submitted = (r2 != undefined)
        ) catch()
    )

    -- Attempt 3 (legacy-style)
    if not submitted then
    (
        try
        (
            local cmd3 = "SubmitToNetwork @\"" + tempScenePath + "\""
            local r3 = execute cmd3
            submitted = (r3 != undefined)
        ) catch()
    )

    submitted
)

fn submitBackburnerJob camNode outputPath jobName =
(
    local success = false

    try
    (
        setRenderStateForSubmission camNode outputPath RENDER_WIDTH RENDER_HEIGHT

        local submissionScene = maxFilePath + maxFileName

        if USE_TEMP_SCENE_PER_JOB then
        (
            local tempScene = buildTempScenePath jobName
            if not (saveTempSceneSnapshot tempScene) then
            (
                ips_log ("ERROR: Could not create temp scene snapshot: " + tempScene)
                return false
            )
            submissionScene = tempScene
        )

        success = submitViaNetRender submissionScene jobName BACKBURNER_MANAGER BACKBURNER_PORT
    )
    catch
    (
        success = false
    )

    success
)

fn allMappedSkus =
(
    local skus = #()
    join skus SIZE_SMALL
    join skus SIZE_MEDIUM
    join skus SIZE_LARGE
    skus
)

/* =========================
   MAIN
   ========================= */
(
    local totalSkus = 0
    local skusFoundInScene = 0
    local skusSkipped = 0
    local jobsAttempted = 0
    local jobsSubmitted = 0
    local errorCount = 0

    ips_initLogFile()
    ips_log "----------------------------------------"
    ips_log "IPS Quartz Backburner submission started."
    ips_log ("Output root: " + OUTPUT_ROOT)
    ips_log ("Quartz matlib: " + QUARTZ_MATLIB)
    ips_log ("Backburner manager: " + BACKBURNER_MANAGER)
    ips_log ("Backburner port: " + (BACKBURNER_PORT as string))
    ips_log ("Render size: " + (RENDER_WIDTH as string) + "x" + (RENDER_HEIGHT as string))
    ips_log ("Use temp scene per job: " + (USE_TEMP_SCENE_PER_JOB as string))
    ips_log ("Dry run: " + (DRY_RUN as string))

    if not doesFileExist QUARTZ_MATLIB then
    (
        ips_log "ERROR: Material library not found. Aborting run."
        return false
    )

    if not (ips_safeMakeDir OUTPUT_ROOT) then
    (
        ips_log "ERROR: Output root could not be created/accessed. Aborting run."
        return false
    )

    if not (ensureTempFolder()) then
    (
        ips_log "ERROR: Temp scene folder could not be created/accessed. Aborting run."
        return false
    )

    local sinkNodes = collectAllSinkNodes()
    ips_log ("Detected sink-like nodes in scene by prefix: " + (sinkNodes.count as string))

    local skus = allMappedSkus()
    totalSkus = skus.count

    for sku in skus do
    (
        ips_log "----------------------------------------"
        ips_log ("Checking SKU: " + sku)

        local sizeGroup = getSizeGroup sku
        if sizeGroup == undefined then
        (
            skusSkipped += 1
            errorCount += 1
            ips_log ("SKIP: No size group mapping for SKU " + sku)
            continue
        )

        local skuNode = getNodeByExactName sku
        if skuNode == undefined then
        (
            skusSkipped += 1
            ips_log ("SKIP: SKU not found in scene: " + sku)
            continue
        )

        skusFoundInScene += 1
        ips_log ("SKU found. Size group: " + sizeGroup)

        local cameraNames = getCamerasForSizeGroup sizeGroup
        if cameraNames == undefined or cameraNames.count != 4 then
        (
            skusSkipped += 1
            errorCount += 1
            ips_log ("SKIP: Camera mapping invalid for size group " + sizeGroup)
            continue
        )

        local camValidation = verifyCameraNodes cameraNames
        local cameraNodes = camValidation[1]
        local missingCameras = camValidation[2]

        if missingCameras.count > 0 then
        (
            skusSkipped += 1
            errorCount += missingCameras.count
            ips_log ("SKIP: Missing required camera(s): " + (arrayToCommaString missingCameras))
            continue
        )

        if not (ensureSkuOutputFolder sku) then
        (
            skusSkipped += 1
            errorCount += 1
            ips_log ("SKIP: Could not create/access output folder for SKU " + sku)
            continue
        )

        for f in FINISHES do
        (
            local finishCode = f[1]
            local matName = f[2]
            ips_log ("Applying finish " + finishCode + " (" + matName + ")")

            local qMat = undefined
            try (qMat = loadQuartzMaterialByName QUARTZ_MATLIB matName) catch (qMat = undefined)
            if qMat == undefined then
            (
                errorCount += 1
                ips_log ("SKIP FINISH: Missing material " + matName)
                continue
            )

            try
            (
                hideAllSinks sinkNodes
                skuNode.isHidden = false
                skuNode.material = qMat
                completeRedraw()
            )
            catch
            (
                errorCount += 1
                ips_log ("ERROR: Failed visibility/material setup for " + sku + " " + finishCode)
                continue
            )

            for i = 1 to 4 do
            (
                local camNode = cameraNodes[i]
                local outputPath = buildOutputFilePath sku finishCode i
                local jobName = sku + "_" + finishCode + "_IPS" + (formattedPrint i format:"02d")

                jobsAttempted += 1
                ips_log ("Submitting camera " + camNode.name + " as job " + jobName)
                ips_log ("Output path: " + outputPath)

                local ok = false
                try (ok = submitBackburnerJob camNode outputPath jobName) catch (ok = false)

                if ok then
                (
                    jobsSubmitted += 1
                    ips_log ("SUBMITTED: " + jobName)
                )
                else
                (
                    errorCount += 1
                    ips_log ("ERROR: Backburner submission failed for " + jobName)
                )
            )
        )

        try (skuNode.isHidden = true) catch()
    )

    hideAllSinks sinkNodes

    ips_log "----------------------------------------"
    ips_log "FINAL SUMMARY"
    ips_log ("Total SKUs in hardcoded table: " + (totalSkus as string))
    ips_log ("Total SKUs found in scene: " + (skusFoundInScene as string))
    ips_log ("Total SKUs skipped: " + (skusSkipped as string))
    ips_log ("Total Backburner jobs attempted: " + (jobsAttempted as string))
    ips_log ("Total Backburner jobs submitted: " + (jobsSubmitted as string))
    ips_log ("Total errors: " + (errorCount as string))
    ips_log "IPS Quartz Backburner submission finished."
    ips_log "----------------------------------------"
)
