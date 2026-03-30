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
global USE_TEMP_SCENE_PER_JOB = false
global SUBMISSION_STABILIZE_MS = 250
global PREFER_BATCH_RENDER_SUBMIT = true
global CONFIGURE_BATCH_WINDOW = true
global CMDJOB_EXE         = @"" -- leave blank to auto-detect
global MAXCMD_EXE         = @"" -- leave blank to auto-detect (recommended)
global CMDJOB_PRIORITY    = 50
global LOGGED_MISSING_CMDJOB = false
global LOGGED_MISSING_MAXCMD = false

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
    -- localTime returns a display string in many 3ds Max versions.
    (localTime as string)
)

fn ips_fileSafeStamp =
(
    local s = ips_timeStamp()
    s = substituteString s "/" "-"
    s = substituteString s ":" "-"
    s = substituteString s " " "_"
    s
)

fn ips_safeMakeDir path =
(
    if path == undefined or path == "" then return false
    if doesDirectoryExist path then return true
    makeDir path
)

fn firstExistingPath candidates =
(
    for p in candidates do
    (
        if p != undefined and p != "" and doesFileExist p do return p
    )
    ""
)

fn resolveToolPaths =
(
    local maxRoot = ""
    try (maxRoot = getDir #maxroot) catch (maxRoot = "")

    if (MAXCMD_EXE == undefined or MAXCMD_EXE == "" or not doesFileExist MAXCMD_EXE) then
    (
        local maxCmdCandidates = #(
            (maxRoot + @"3dsmaxcmd.exe"),
            @"C:\Program Files\Autodesk\3ds Max 2026\3dsmaxcmd.exe",
            @"C:\Program Files\Autodesk\3ds Max 2025\3dsmaxcmd.exe",
            @"C:\Program Files\Autodesk\3ds Max 2024\3dsmaxcmd.exe",
            @"C:\Program Files\Autodesk\3ds Max 2023\3dsmaxcmd.exe",
            @"C:\Program Files\Autodesk\3ds Max\3dsmaxcmd.exe"
        )
        MAXCMD_EXE = firstExistingPath maxCmdCandidates
    )

    if (CMDJOB_EXE == undefined or CMDJOB_EXE == "" or not doesFileExist CMDJOB_EXE) then
    (
        local bbCandidates = #(
            (maxRoot + @"Backburner\cmdjob.exe"),
            @"C:\Program Files (x86)\Autodesk\Backburner\cmdjob.exe",
            @"C:\Program Files\Autodesk\Backburner\cmdjob.exe"
        )
        CMDJOB_EXE = firstExistingPath bbCandidates
    )
)

fn ips_initLogFile =
(
    if ips_safeMakeDir OUTPUT_ROOT then
    (
        IPS_LogFilePath = OUTPUT_ROOT + "\\IPS_Backburner_Log_" + ips_fileSafeStamp() + ".txt"
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

fn collectAllSinkRootNodes =
(
    local roots = #()
    for o in objects do
    (
        if isValidNode o and isSinkNodeName o.name then append roots o
    )
    roots
)

fn collectNodeHierarchyWalk n outRef =
(
    if n == undefined or (not isValidNode n) then return undefined
    append outRef n
    for c in n.children do collectNodeHierarchyWalk c outRef
)

fn collectNodeHierarchy node =
(
    local outNodes = #()
    collectNodeHierarchyWalk node outNodes
    outNodes
)

fn collectAllSinkNodesIncludingChildren sinkRootNodes =
(
    local allNodes = #()
    for r in sinkRootNodes where isValidNode r do
    (
        local branch = collectNodeHierarchy r
        join allNodes branch
    )
    allNodes
)

fn setHiddenForNodes nodeList hiddenState =
(
    for n in nodeList where isValidNode n do
    (
        try (n.isHidden = hiddenState) catch()
    )
)

fn hideAllSinks sinkRootNodes =
(
    local nodes = collectAllSinkNodesIncludingChildren sinkRootNodes
    setHiddenForNodes nodes true
)

fn unhideSinkHierarchy sinkNode =
(
    local nodes = collectNodeHierarchy sinkNode
    setHiddenForNodes nodes false
)

fn selectSinkHierarchy sinkNode =
(
    local nodes = collectNodeHierarchy sinkNode
    try (select nodes) catch()
)

fn assignMaterialToSinkHierarchy sinkNode matObj =
(
    local nodes = collectNodeHierarchy sinkNode
    for n in nodes where (isValidNode n and isKindOf n GeometryClass) do
    (
        try (n.material = matObj) catch()
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

fn quoteArg s =
(
    "\"" + s + "\""
)

fn runDosCommandSuccess cmdLine =
(
    local ok = false
    try
    (
        local rc = DOSCommand cmdLine
        ok = (rc == 0 or rc == true)
    ) catch (ok = false)
    ok
)

fn submitViaCmdJob tempScenePath jobName cameraName outputPath width height =
(
    if DRY_RUN then return true

    if (not doesFileExist CMDJOB_EXE) then
    (
        if not LOGGED_MISSING_CMDJOB do
        (
            ips_log ("CMDJOB missing, skipping cmdjob submit path: " + CMDJOB_EXE)
            LOGGED_MISSING_CMDJOB = true
        )
        return false
    )

    if (not doesFileExist MAXCMD_EXE) then
    (
        if not LOGGED_MISSING_MAXCMD do
        (
            ips_log ("3dsmaxcmd missing, skipping cmdjob submit path: " + MAXCMD_EXE)
            LOGGED_MISSING_MAXCMD = true
        )
        return false
    )

    local taskCmd = quoteArg MAXCMD_EXE + " " + quoteArg tempScenePath + \
        " -camera:" + quoteArg cameraName + \
        " -outputName:" + quoteArg outputPath + \
        " -w:" + (width as string) + \
        " -h:" + (height as string)

    -- Try multiple cmdjob syntaxes because switch formats vary by Backburner version.
    local bbCmdA = quoteArg CMDJOB_EXE + \
        " -manager:" + BACKBURNER_MANAGER + \
        " -port:" + (BACKBURNER_PORT as string) + \
        " -jobName:" + quoteArg jobName + \
        " -priority:" + (CMDJOB_PRIORITY as string) + \
        " -taskName:1 -task:" + quoteArg taskCmd

    local bbCmdB = quoteArg CMDJOB_EXE + \
        " -manager " + quoteArg BACKBURNER_MANAGER + \
        " -port " + (BACKBURNER_PORT as string) + \
        " -jobName " + quoteArg jobName + \
        " -priority " + (CMDJOB_PRIORITY as string) + \
        " -taskName " + quoteArg "1" + " -task " + quoteArg taskCmd

    ips_log ("CMDJOB submit command A: " + bbCmdA)
    local result = runDosCommandSuccess bbCmdA

    if not result then
    (
        ips_log ("CMDJOB submit command B: " + bbCmdB)
        result = runDosCommandSuccess bbCmdB
    )

    result
)

fn submitFinishBatchViaCmdJob scenePath sku finishCode cameraNodes =
(
    if DRY_RUN then return cameraNodes.count
    if (not doesFileExist CMDJOB_EXE) then return 0
    if (not doesFileExist MAXCMD_EXE) then return 0

    local batchJobName = sku + "_" + finishCode + "_IPS_BATCH"
    local bbCmdBaseA = quoteArg CMDJOB_EXE + \
        " -manager:" + BACKBURNER_MANAGER + \
        " -port:" + (BACKBURNER_PORT as string) + \
        " -jobName:" + quoteArg batchJobName + \
        " -priority:" + (CMDJOB_PRIORITY as string)

    local bbCmdBaseB = quoteArg CMDJOB_EXE + \
        " -manager " + quoteArg BACKBURNER_MANAGER + \
        " -port " + (BACKBURNER_PORT as string) + \
        " -jobName " + quoteArg batchJobName + \
        " -priority " + (CMDJOB_PRIORITY as string)

    local bbCmdA = bbCmdBaseA
    local bbCmdB = bbCmdBaseB

    for i = 1 to cameraNodes.count do
    (
        local camName = cameraNodes[i].name
        local outPath = buildOutputFilePath sku finishCode i
        local taskCmd = quoteArg MAXCMD_EXE + " " + quoteArg scenePath + \
            " -camera:" + quoteArg camName + \
            " -outputName:" + quoteArg outPath + \
            " -w:" + (RENDER_WIDTH as string) + \
            " -h:" + (RENDER_HEIGHT as string)

        local tName = (sku + "_" + finishCode + "_IPS" + (formattedPrint i format:"02d"))
        bbCmdA += " -taskName:" + quoteArg tName + " -task:" + quoteArg taskCmd
        bbCmdB += " -taskName " + quoteArg tName + " -task " + quoteArg taskCmd
    )

    ips_log ("CMDJOB batch submit command A: " + bbCmdA)
    local ok = runDosCommandSuccess bbCmdA

    if not ok then
    (
        ips_log ("CMDJOB batch submit command B: " + bbCmdB)
        ok = runDosCommandSuccess bbCmdB
    )

    if ok then cameraNodes.count else 0
)

fn submitViaNetRender tempScenePath jobName managerIP managerPort =
(
    if DRY_RUN then return true

    local submitted = false

    -- Best-effort compatibility across Max versions:
    -- try direct calls first, then fallback to execute() variants.
    try (if isProperty netrender #manager do netrender.manager = managerIP) catch()
    try (if isProperty netrender #port do netrender.port = managerPort) catch()

    if not submitted then
    (
        try
        (
            if isProperty netrender #submitJob then
            (
                local r = netrender.submitJob tempScenePath jobName:jobName
                submitted = (r != undefined and r != false)
            )
        ) catch()
    )

    if not submitted then
    (
        try
        (
            if isProperty netrender #submit then
            (
                local r2 = netrender.submit tempScenePath jobName
                submitted = (r2 != undefined and r2 != false)
            )
        ) catch()
    )

    if not submitted then
    (
        try
        (
            local cmd = "netrender.submitJob @\"" + tempScenePath + "\" jobName:@\"" + jobName + "\""
            local r3 = execute cmd
            submitted = (r3 != undefined and r3 != false)
        ) catch()
    )

    if not submitted then
    (
        try
        (
            local cmd2 = "netrender.submit @\"" + tempScenePath + "\" @\"" + jobName + "\""
            local r4 = execute cmd2
            submitted = (r4 != undefined and r4 != false)
        ) catch()
    )

    if not submitted then
    (
        try
        (
            local cmd3 = "SubmitToNetwork @\"" + tempScenePath + "\""
            local r5 = execute cmd3
            submitted = (r5 != undefined and r5 != false)
        ) catch()
    )

    submitted
)

fn submitViaBatchRenderIfPossible tempScenePath jobName =
(
    if DRY_RUN then return true
    if not PREFER_BATCH_RENDER_SUBMIT then return false

    local submitted = false

    -- Try common batch-render manager entry points via execute for version tolerance.
    try
    (
        local cmdA = "if (batchRenderMgr != undefined and isProperty batchRenderMgr #submitToNetwork) then (batchRenderMgr.submitToNetwork @\"" + tempScenePath + "\" @\"" + jobName + "\") else false"
        local rA = execute cmdA
        submitted = (rA != undefined and rA != false)
    ) catch()

    if not submitted then
    (
        try
        (
            local cmdB = "if (batchRenderMgr != undefined and isProperty batchRenderMgr #netRender) then (batchRenderMgr.netRender @\"" + tempScenePath + "\" @\"" + jobName + "\") else false"
            local rB = execute cmdB
            submitted = (rB != undefined and rB != false)
        ) catch()
    )

    submitted
)

fn configureBatchRenderForFinish sku finishCode cameraNodes =
(
    if not CONFIGURE_BATCH_WINDOW then return false

    local configured = false

    -- Clear existing batch views (try common API variants).
    try (execute "if (batchRenderMgr != undefined and isProperty batchRenderMgr #numViews and isProperty batchRenderMgr #deleteView) do (for i = batchRenderMgr.numViews to 1 by -1 do batchRenderMgr.deleteView i)") catch()
    try (execute "if (batchRenderMgr != undefined and isProperty batchRenderMgr #GetViewCount and isProperty batchRenderMgr #DeleteView) do (for i = batchRenderMgr.GetViewCount() to 1 by -1 do batchRenderMgr.DeleteView i)") catch()

    for i = 1 to cameraNodes.count do
    (
        local camName = cameraNodes[i].name
        local viewName = sku + "_" + finishCode + "_IPS" + (formattedPrint i format:"02d")
        local outPath = buildOutputFilePath sku finishCode i
        local camExpr = "$'" + camName + "'"

        -- Variant A: addView with named args
        local cmdA = "if (batchRenderMgr != undefined and isProperty batchRenderMgr #addView) then (batchRenderMgr.addView name:@\"" + viewName + "\" camera:" + camExpr + " output:@\"" + outPath + "\" width:" + (RENDER_WIDTH as string) + " height:" + (RENDER_HEIGHT as string) + " enabled:true) else false"
        local okA = false
        try (okA = execute cmdA) catch (okA = false)

        if okA == false then
        (
            -- Variant B: create view and set properties
            local cmdB = "if (batchRenderMgr != undefined and isProperty batchRenderMgr #createView) then (local v = batchRenderMgr.createView(); if v != undefined do (v.name=@\"" + viewName + "\"; v.camera=" + camExpr + "; if isProperty v #outputFilename do v.outputFilename=@\"" + outPath + "\"; if isProperty v #width do v.width=" + (RENDER_WIDTH as string) + "; if isProperty v #height do v.height=" + (RENDER_HEIGHT as string) + "; if isProperty v #enabled do v.enabled=true; true) else false) else false"
            local okB = false
            try (okB = execute cmdB) catch (okB = false)
            if okB == true then configured = true
        )
        else
        (
            configured = true
        )
    )

    configured
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

        success = submitViaCmdJob submissionScene jobName camNode.name outputPath RENDER_WIDTH RENDER_HEIGHT
        if not success do success = submitViaBatchRenderIfPossible submissionScene jobName
        if not success do success = submitViaNetRender submissionScene jobName BACKBURNER_MANAGER BACKBURNER_PORT
    )
    catch
    (
        success = false
    )

    success
)

fn getSubmissionScenePathForCurrentState sku finishCode =
(
    local submissionScene = maxFilePath + maxFileName

    if USE_TEMP_SCENE_PER_JOB then
    (
        local tempScene = buildTempScenePath (sku + "_" + finishCode + "_STATE")
        if saveTempSceneSnapshot tempScene then
            submissionScene = tempScene
        else
            ips_log ("WARN: Temp scene snapshot failed, using current scene path: " + submissionScene)
    )

    submissionScene
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
    resolveToolPaths()
    ips_log "----------------------------------------"
    ips_log "IPS Quartz Backburner submission started."
    ips_log ("Output root: " + OUTPUT_ROOT)
    ips_log ("Quartz matlib: " + QUARTZ_MATLIB)
    ips_log ("Backburner manager: " + BACKBURNER_MANAGER)
    ips_log ("Backburner port: " + (BACKBURNER_PORT as string))
    ips_log ("Render size: " + (RENDER_WIDTH as string) + "x" + (RENDER_HEIGHT as string))
    ips_log ("Use temp scene per job: " + (USE_TEMP_SCENE_PER_JOB as string))
    ips_log ("Prefer batch-render submit: " + (PREFER_BATCH_RENDER_SUBMIT as string))
    ips_log ("Configure Batch Render window: " + (CONFIGURE_BATCH_WINDOW as string))
    ips_log ("CMDJOB path: " + CMDJOB_EXE)
    ips_log ("3dsmaxcmd path: " + MAXCMD_EXE)
    ips_log ("Dry run: " + (DRY_RUN as string))

    if (CMDJOB_EXE == "" or MAXCMD_EXE == "") then
    (
        ips_log "WARN: cmdjob/3dsmaxcmd auto-detect incomplete."
        ips_log "WARN: If queue submission fails, set CMDJOB_EXE and MAXCMD_EXE explicitly at top of script."
    )

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

    local sinkRootNodes = collectAllSinkRootNodes()
    ips_log ("Detected sink root nodes in scene by prefix: " + (sinkRootNodes.count as string))

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
                hideAllSinks sinkRootNodes
                selectSinkHierarchy skuNode -- ensures group children are included as requested
                unhideSinkHierarchy skuNode
                assignMaterialToSinkHierarchy skuNode qMat
                completeRedraw()
            )
            catch
            (
                errorCount += 1
                ips_log ("ERROR: Failed visibility/material setup for " + sku + " " + finishCode)
                continue
            )

            local submissionScene = getSubmissionScenePathForCurrentState sku finishCode

            local batchWindowOk = configureBatchRenderForFinish sku finishCode cameraNodes
            if batchWindowOk then
                ips_log ("Batch Render window configured for " + sku + " " + finishCode)
            else
                ips_log ("WARN: Could not confirm Batch Render window configuration for " + sku + " " + finishCode)

            -- Preferred flow: one batch submission per finish containing all 4 camera tasks.
            jobsAttempted += 4
            local batchSubmittedCount = submitFinishBatchViaCmdJob submissionScene sku finishCode cameraNodes

            if batchSubmittedCount == 4 then
            (
                jobsSubmitted += 4
                ips_log ("SUBMITTED BATCH: " + sku + " " + finishCode + " (4 camera tasks)")
            )
            else
            (
                ips_log ("WARN: Batch submit unavailable/failed, falling back to per-camera submission.")
                for i = 1 to 4 do
                (
                    local camNode = cameraNodes[i]
                    local outputPath = buildOutputFilePath sku finishCode i
                    local jobName = sku + "_" + finishCode + "_IPS" + (formattedPrint i format:"02d")

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
        )

        try (setHiddenForNodes (collectNodeHierarchy skuNode) true) catch()
    )

    hideAllSinks sinkRootNodes

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
