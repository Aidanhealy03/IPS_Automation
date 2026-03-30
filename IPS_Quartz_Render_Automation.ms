-- =============================================================================
-- IPS_Quartz_Render_Automation.ms
-- Batch Render -> Net Render (Backburner) workflow
--
-- Uses the same core method as the provided IGR script:
--   1) Set scene state (hide all sinks, unhide one sink, assign finish)
--   2) Save frozen temp scene per SKU+finish
--   3) Build 4 Batch Render views (camera + output file)
--   4) Enable Net Render and submit via batchRenderMgr.render()
-- =============================================================================

/* =========================
   USER SETTINGS
   ========================= */
OUTPUT_ROOT        = @"R:\Aidan\IPS"
QUARTZ_MATLIB      = @"R:\Creative\3D Library\3D Library\Material Library\Quartz.mat"
BACKBURNER_MANAGER = "10.10.0.59"
TEMP_SCENE_FOLDER  = @"R:\Aidan\IPS\_TempScenes"
RENDER_WIDTH       = 2000
RENDER_HEIGHT      = 2000
JPG_QUALITY        = 100
DRY_RUN            = false

LOG_FILE_PATH = OUTPUT_ROOT + "\\IPS_RenderLog.txt"

/* =========================
   HARD CODED TABLES
   ========================= */
FINISH_CODES = #("WH","BL","CN","GR","BI","BR")
FINISH_MATS  = #("White_Quartz","Black_Quartz","Concrete_Quartz_02","Grey_Quartz_02","Bisque_Quartz_02","Brown_Quartz_02")

SMALL_CAMERAS  = #("Corona Camera001","Corona Camera002","Corona Camera003","Corona Camera004")
MEDIUM_CAMERAS = #("Corona Camera005","Corona Camera006","Corona Camera007","Corona Camera008")
LARGE_CAMERAS  = #("Corona Camera009","Corona Camera010","Corona Camera011","Corona Camera012")

SMALL_SKUS = #("QT-825","QU-690","Q-315","Q-306","Q-309")
MEDIUM_SKUS = #("Q-320")
LARGE_SKUS = #(
    "Q-340","QU-670","QU-610","QU-711","QU-712","Q-360R","QU-710","QUWS-875","Q-350",
    "QT-610","QT-670","QT-710","QT-711","QT-712","QTWS-875","QTWS-880","QUWS-880",
    "QA-740","QA-750","QA-760","QAR-740","QAR-750","QAR-760","QARWS-740","QAWS-740"
)

SINK_PREFIXES = #("QARWS","QUWS","QTWS","QAWS","QAR","QA","QU","QT","Q")

/* =========================
   GLOBAL STATE
   ========================= */
ALL_SKUS = #()
g_totalSKUs = 0
g_foundSKUs = 0
g_skippedSKUs = 0
g_jobsTried = 0
g_jobsOK = 0
g_errors = 0
g_logStream = undefined
g_matLib = undefined

/* =========================
   HELPERS
   ========================= */
fn logMsg msg = (
    format "%\n" msg
    if g_logStream != undefined do (try (format "%\n" msg to:g_logStream; flush g_logStream) catch())
)

fn ensureFolder p = (
    if doesFileExist p then return true
    try (makeDir p all:true; doesFileExist p) catch (false)
)

fn isSinkNode nodeName = (
    for pfx in SINK_PREFIXES do if matchPattern nodeName pattern:(pfx + "*") do return true
    false
)

fn getAllSinkNodes = (
    local arr = #()
    for n in objects where isSinkNode n.name do append arr n
    arr
)

fn getManagedSinkRoots = (
    local arr = #()
    for sku in ALL_SKUS do (
        local n = getNodeByName sku exact:true
        if n != undefined do append arr n
    )
    arr
)

fn getSizeGroup sku = (
    for s in SMALL_SKUS do if s == sku then return "SMALL"
    for s in MEDIUM_SKUS do if s == sku then return "MEDIUM"
    for s in LARGE_SKUS do if s == sku then return "LARGE"
    ""
)

fn getCamNamesForGroup grp = (
    case grp of (
        "SMALL": SMALL_CAMERAS
        "MEDIUM": MEDIUM_CAMERAS
        "LARGE": LARGE_CAMERAS
        default: #()
    )
)

fn hideAllSinks sinkArr = (for n in sinkArr do try(n.isHidden = true)catch())

fn collectHierarchyWalk n arr = (
    if isValidNode n then (
        append arr n
        for c in n.children do collectHierarchyWalk c arr
    )
)

fn collectHierarchy root = (
    local out = #()
    collectHierarchyWalk root out
    out
)

fn unhideSinkHierarchy sinkNode = (
    local nodes = collectHierarchy sinkNode
    try(select nodes)catch()
    for n in nodes do try(n.isHidden = false)catch()
)

fn hideAllSinkHierarchies sinkRootArr = (
    for r in sinkRootArr where isValidNode r do (
        local nodes = collectHierarchy r
        for n in nodes do try(n.isHidden = true)catch()
    )
)

fn assignMaterialHierarchy sinkNode matObj = (
    local nodes = collectHierarchy sinkNode
    for n in nodes where isKindOf n GeometryClass do try(n.material = matObj)catch()
)

fn loadMatLib = (
    if g_matLib != undefined then return true
    if not doesFileExist QUARTZ_MATLIB then return false
    try (g_matLib = loadTempMaterialLibrary QUARTZ_MATLIB; g_matLib != undefined) catch(false)
)

fn getMatByName matName = (
    if g_matLib == undefined then return undefined
    for i = 1 to g_matLib.count do (
        local m = g_matLib[i]
        if m != undefined and m.name == matName do return m
    )
    undefined
)

fn buildOutPath sku finCode ipsIdx = (
    local num = if ipsIdx < 10 then ("0" + ipsIdx as string) else (ipsIdx as string)
    OUTPUT_ROOT + "\\" + sku + "\\" + sku + "_" + finCode + "_IPS" + num + ".jpg"
)

fn buildTempScenePath sku finCode = (TEMP_SCENE_FOLDER + "\\" + sku + "_" + finCode + ".max")

fn clearBatchViews = (
    -- FIX: deleteView expects an integer index, not getView() interface.
    while (batchRenderMgr.numViews > 0) do (
        try (batchRenderMgr.deleteView 1) catch (exit)
    )
)

fn setJpgQuality = (
    try (renderers.current.output_jpeg_quality = JPG_QUALITY) catch()
    try (JPEGIO.setQuality JPG_QUALITY) catch()
)

fn configureBatchNetRender managerIp = (
    try (batchRenderMgr.netRender = true) catch()
    try (batchRenderMgr.networkRender = true) catch()
    try (batchRenderMgr.useNetRender = true) catch()
    try (batchRenderMgr.managerAddress = managerIp) catch()
    try (batchRenderMgr.manager = managerIp) catch()
    try (batchRenderMgr.serverName = managerIp) catch()
    try (execute "if (batchRenderMgr != undefined and isProperty batchRenderMgr #netRender) do (batchRenderMgr.netRender = true)") catch()
    try (execute "if (batchRenderMgr != undefined and isProperty batchRenderMgr #networkRender) do (batchRenderMgr.networkRender = true)") catch()
    try (execute ("if (batchRenderMgr != undefined and isProperty batchRenderMgr #managerAddress) do (batchRenderMgr.managerAddress = \"" + managerIp + "\")")) catch()
)

fn isBatchNetRenderEnabled = (
    local enabled = false
    try (if batchRenderMgr.netRender == true then enabled = true) catch()
    try (if batchRenderMgr.networkRender == true then enabled = true) catch()
    enabled
)

/* =========================
   MAIN
   ========================= */
(
    ALL_SKUS = #(); for s in SMALL_SKUS do append ALL_SKUS s; for s in MEDIUM_SKUS do append ALL_SKUS s; for s in LARGE_SKUS do append ALL_SKUS s
    g_totalSKUs = ALL_SKUS.count

    ensureFolder OUTPUT_ROOT
    ensureFolder TEMP_SCENE_FOLDER
    try (g_logStream = createFile LOG_FILE_PATH) catch(g_logStream = undefined)

    logMsg "============================================================"
    logMsg "IPS Quartz Batch Render Net Render"
    logMsg ("Output Root  : " + OUTPUT_ROOT)
    logMsg ("Material Lib : " + QUARTZ_MATLIB)
    logMsg ("BB Manager   : " + BACKBURNER_MANAGER)
    logMsg ("Temp Scenes  : " + TEMP_SCENE_FOLDER)
    logMsg ("Resolution   : " + RENDER_WIDTH as string + " x " + RENDER_HEIGHT as string)
    logMsg ("Dry Run      : " + DRY_RUN as string)

    if not loadMatLib() then (
        logMsg "[FATAL] Cannot load material library."; if g_logStream != undefined do close g_logStream; return undefined
    )

    local allSinks = getAllSinkNodes()
    local managedSinkRoots = getManagedSinkRoots()
    logMsg ("Sink nodes in scene: " + allSinks.count as string)
    logMsg ("Managed sink roots from SKU table: " + managedSinkRoots.count as string)

    for sku in ALL_SKUS do (
        logMsg "------------------------------------------------------------"
        logMsg (">>> SKU: " + sku)

        local grp = getSizeGroup sku
        if grp == "" then (g_skippedSKUs += 1; logMsg "  [SKIP] Not mapped"; continue)

        local sinkNode = getNodeByName sku exact:true
        if sinkNode == undefined then (g_skippedSKUs += 1; logMsg "  [SKIP] Node not found"; continue)
        g_foundSKUs += 1

        local camNames = getCamNamesForGroup grp
        local camArr = #(); local camOK = true
        for cn in camNames do (
            local c = getNodeByName cn exact:true
            if c == undefined then (camOK = false; g_errors += 1; logMsg ("  [ERROR] Camera missing: " + cn); exit)
            append camArr c
        )
        if not camOK then (g_skippedSKUs += 1; continue)

        local skuDir = OUTPUT_ROOT + "\\" + sku
        if not ensureFolder skuDir then (g_skippedSKUs += 1; g_errors += 1; logMsg "  [ERROR] Output dir failed"; continue)

        for fi = 1 to FINISH_CODES.count do (
            local finCode = FINISH_CODES[fi]
            local matName = FINISH_MATS[fi]
            logMsg ("  -- Finish: " + finCode + " [" + matName + "]")

            local mat = getMatByName matName
            if mat == undefined then (g_errors += 1; logMsg "    [SKIP] Material missing"; continue)

            hideAllSinkHierarchies managedSinkRoots
            unhideSinkHierarchy sinkNode
            assignMaterialHierarchy sinkNode mat
            setJpgQuality()
            completeRedraw()

            local tempPath = buildTempScenePath sku finCode
            local snapOK = false
            if DRY_RUN then (snapOK = true; logMsg ("    [DRY RUN] Save snapshot: " + tempPath))
            else (
                try (saveMaxFile tempPath clearNeedSaveFlag:false; snapOK = true; logMsg ("    [SNAP] " + tempPath))
                catch (g_errors += 1; logMsg ("    [ERROR] saveMaxFile failed: " + getCurrentException()))
            )
            if not snapOK then continue

            clearBatchViews()
            local viewsOK = true

            for ci = 1 to camArr.count do (
                local cam = camArr[ci]
                local outFile = buildOutPath sku finCode ci
                local vName = sku + "_" + finCode + "_IPS" + (if ci < 10 then ("0" + ci as string) else (ci as string))
                logMsg ("    [VIEW] " + vName + " | " + cam.name + " -> " + outFile)

                g_jobsTried += 1

                if not DRY_RUN then (
                    local bv = undefined
                    try (bv = batchRenderMgr.addView cam) catch (bv = undefined)
                    if bv == undefined then (
                        g_errors += 1; viewsOK = false; logMsg ("    [ERROR] addView failed for " + cam.name); exit
                    )
                    try (bv.outputFilename = outFile) catch()
                    try (bv.width = RENDER_WIDTH) catch()
                    try (bv.height = RENDER_HEIGHT) catch()
                    try (bv.frameBegin = 0; bv.frameEnd = 0) catch()
                    try (bv.name = vName) catch()
                    try (bv.enabled = true) catch()
                )
            )

            if not viewsOK then continue

            if DRY_RUN then (
                g_jobsOK += 4
                logMsg ("    [DRY RUN] Would submit batch: " + sku + "_" + finCode)
            )
            else (
                try (
                    batchRenderMgr.renderSceneFilename = tempPath
                    configureBatchNetRender BACKBURNER_MANAGER
                    if not isBatchNetRenderEnabled() then logMsg "    [WARN] Could not verify Net Render flag ON before submit."
                    batchRenderMgr.render()
                    g_jobsOK += 4
                    logMsg ("    [OK] Submitted batch: " + sku + "_" + finCode)
                )
                catch (
                    g_errors += 1
                    logMsg ("    [ERROR] Batch submit failed: " + sku + "_" + finCode + " | " + getCurrentException())
                )
            )
        )

        clearBatchViews()
        hideAllSinkHierarchies managedSinkRoots
    )

    for n in allSinks do try(n.isHidden = false)catch()

    logMsg "============================================================"
    logMsg ("Total SKUs in table : " + g_totalSKUs as string)
    logMsg ("SKUs found in scene : " + g_foundSKUs as string)
    logMsg ("SKUs skipped        : " + g_skippedSKUs as string)
    logMsg ("Jobs attempted      : " + g_jobsTried as string)
    logMsg ("Jobs submitted OK   : " + g_jobsOK as string)
    logMsg ("Errors              : " + g_errors as string)
    logMsg "============================================================"

    if g_logStream != undefined then try(close g_logStream)catch()
)
