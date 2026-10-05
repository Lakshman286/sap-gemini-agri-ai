*&---------------------------------------------------------------------*
*& Report ZTEST_REPORT_058
*& Hybrid SAP Table Master Data Analysis + Google Gemini AI Bridge
*& Auto-Export Advisory Records into Database Table ZAGRI_AI_QUEUE
*&---------------------------------------------------------------------*
REPORT ztest_report_058.

TABLES: sscrfields.

*----------------------------------------------------------------------*
* Type Definitions for AI Bridge Response
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_ai_response,
         season           TYPE string,
         soil_condition   TYPE string,
         recommended_crop TYPE string,
         fert_id          TYPE string,
         std_dosage_acre  TYPE string,
         advisory_note    TYPE string,
       END OF ty_ai_response.

*----------------------------------------------------------------------*
* Selection Screen: Survey Inputs from Field Officer
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_input WITH FRAME TITLE text_001.
  PARAMETERS: p_reqid TYPE zagri_de_reqid    OBLIGATORY,
              p_asnid TYPE zagri_de_asnid    MODIF ID dis,
              p_offid TYPE zagri_de_oid      MODIF ID dis,
              p_zone  TYPE char30            MODIF ID dis,
              p_sdate TYPE sy-datum          DEFAULT sy-datum OBLIGATORY,
              p_stype TYPE zagri_de_stype    OBLIGATORY DEFAULT 'CLAY',
              p_rcrop TYPE zagri_de_cropname OBLIGATORY DEFAULT 'Paddy',
              p_ph    TYPE zagri_de_ph       OBLIGATORY DEFAULT '6.50',
              p_moist TYPE zagri_de_moist    OBLIGATORY DEFAULT '25.00',
              p_n     TYPE i                 OBLIGATORY DEFAULT 120,
              p_p     TYPE i                 OBLIGATORY DEFAULT 15,
              p_k     TYPE i                 OBLIGATORY DEFAULT 40.
SELECTION-SCREEN END OF BLOCK b_input.

*----------------------------------------------------------------------*
* Selection Screen: AI Bridge Configuration (FastAPI Endpoint)
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_api WITH FRAME TITLE text_002.
  PARAMETERS: p_apiurl TYPE string LOWER CASE
                       DEFAULT 'http://127.0.0.1:8000/predict' OBLIGATORY.
SELECTION-SCREEN END OF BLOCK b_api.

SELECTION-SCREEN SKIP 1.
SELECTION-SCREEN BEGIN OF LINE.
  SELECTION-SCREEN PUSHBUTTON 12(34) btn_eval USER-COMMAND cmd_eval.
SELECTION-SCREEN END OF LINE.

*----------------------------------------------------------------------*
* Global Controls for Dialog Popup
*----------------------------------------------------------------------*
DATA: go_dialog TYPE REF TO cl_gui_dialogbox_container,
      go_html   TYPE REF TO cl_gui_html_viewer.

CLASS lcl_event_handler DEFINITION.
  PUBLIC SECTION.
    CLASS-METHODS on_close FOR EVENT close OF cl_gui_dialogbox_container
      IMPORTING sender.
    CLASS-METHODS on_sapevent FOR EVENT sapevent OF cl_gui_html_viewer
      IMPORTING action.
ENDCLASS.

CLASS lcl_event_handler IMPLEMENTATION.
  METHOD on_close.
    sender->free( ).
    CLEAR go_dialog.
  ENDMETHOD.

  METHOD on_sapevent.
    IF action = 'CLOSE_MODAL'.
      IF go_dialog IS BOUND.
        go_dialog->free( ).
        CLEAR go_dialog.
      ENDIF.
    ENDIF.
  ENDMETHOD.
ENDCLASS.

*----------------------------------------------------------------------*
* Initialization & Screen Settings
*----------------------------------------------------------------------*
INITIALIZATION.
  text_001 = 'Field Officer Survey Input'.
  text_002 = 'Google Gemini AI Bridge Endpoint'.
  btn_eval = 'RUN HYBRID CROP & AI ADVISORY'.
  %_p_zone_%_app_%-text  = 'Assigned Zone'.
  %_p_rcrop_%_app_%-text = 'Farmer Requested Crop'.
  %_p_apiurl_%_app_%-text = 'AI Bridge URL'.

AT SELECTION-SCREEN OUTPUT.
  LOOP AT SCREEN.
    IF screen-group1 = 'DIS'.
      screen-input = '0'.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

*----------------------------------------------------------------------*
* Auto-fill Assigned Zone & Officer from Master Assignment Tables
*----------------------------------------------------------------------*
AT SELECTION-SCREEN ON p_reqid.
  IF p_reqid IS NOT INITIAL.
    CLEAR: p_asnid, p_offid, p_zone.
    SELECT SINGLE assign_id, officer_id
      FROM zagri_off_assign
      INTO (@p_asnid, @p_offid)
      WHERE req_id = @p_reqid.

    SELECT SINGLE assigned_zone
      FROM zagri_officer
      INTO @p_zone
      WHERE officer_id = @p_offid.

    IF p_zone IS INITIAL.
      p_zone = 'NTR EAST'.
    ENDIF.
  ENDIF.

*----------------------------------------------------------------------*
* Action Handling: Master Data Analysis & Independent Inference
*----------------------------------------------------------------------*
AT SELECTION-SCREEN.
  CASE sscrfields-ucomm.

    WHEN 'CMD_EVAL'.
      DATA: lv_month      TYPE numc2,
            lv_season     TYPE char10,
            lv_crop       TYPE string,
            lv_fert       TYPE string,
            lv_dose       TYPE string,
            lv_num_dosage TYPE zagri_de_qty,
            lv_clean_dose TYPE string,
            lv_cond       TYPE string,
            lv_source     TYPE string,
            lv_note       TYPE string,
            lt_html       TYPE TABLE OF char255,
            lv_url        TYPE char255,
            lv_st_name    TYPE string,
            lv_texture    TYPE string,
            lv_perm       TYPE string,
            lv_yield      TYPE char10,
            lv_water      TYPE char20,
            lt_events     TYPE cntl_simple_events,
            ls_event      TYPE cntl_simple_event,
            ls_ai_res     TYPE ty_ai_response,
            lv_err_msg    TYPE string,
            ls_ai_queue   TYPE zagri_ai_queue,
            lv_db_status  TYPE string.

      " Ensure Zone/Region is populated
      IF p_zone IS INITIAL AND p_reqid IS NOT INITIAL.
        SELECT SINGLE assign_id, officer_id
          FROM zagri_off_assign
          INTO (@p_asnid, @p_offid)
          WHERE req_id = @p_reqid.

        SELECT SINGLE assigned_zone
          FROM zagri_officer
          INTO @p_zone
          WHERE officer_id = @p_offid.

        IF p_zone IS INITIAL.
          p_zone = 'NTR EAST'.
        ENDIF.
      ENDIF.

      IF p_zone IS INITIAL.
        MESSAGE 'Region/Zone is missing. Please enter a valid Request ID.' TYPE 'E'.
        RETURN.
      ENDIF.

      " 1. Derive Season from Survey Date
      lv_month = p_sdate+4(2).
      IF lv_month >= '06' AND lv_month <= '10'.
        lv_season = 'Kharif'.
      ELSEIF lv_month >= '11' OR lv_month <= '02'.
        lv_season = 'Rabi'.
      ELSE.
        lv_season = 'Zaid'.
      ENDIF.

      " 2. Soil pH Condition
      IF p_ph < '6.50'.
        lv_cond = 'ACIDIC'.
      ELSEIF p_ph > '7.50'.
        lv_cond = 'ALKALINE'.
      ELSE.
        lv_cond = 'NEUTRAL'.
      ENDIF.

      " 3. Retrieve Soil Master Details with Fallback
      CLEAR: lv_st_name, lv_texture, lv_perm.
      SELECT SINGLE soil_name, soil_texture, permeability
        FROM zagri_soil_type
        INTO (@lv_st_name, @lv_texture, @lv_perm)
        WHERE soil_type_id = @p_stype.

      IF sy-subrc <> 0 OR lv_st_name IS INITIAL.
        IF p_stype CS 'CLAY'.
          lv_st_name = 'Clayey Soil'.
          lv_texture = 'Fine-textured, dense with high water-holding capacity'.
          lv_perm    = 'LOW'.
        ELSEIF p_stype CS 'SAND'.
          lv_st_name = 'Sandy Loam Soil'.
          lv_texture = 'Coarse, porous with rapid drainage'.
          lv_perm    = 'HIGH'.
        ELSEIF p_stype CS 'BLACK'.
          lv_st_name = 'Black Cotton Soil (Regur)'.
          lv_texture = 'Heavy clayey, expands when wet and cracks when dry'.
          lv_perm    = 'MODERATE'.
        ELSE.
          lv_st_name = |Soil Code: { p_stype }|.
          lv_texture = 'Loamy mineral texture'.
          lv_perm    = 'MODERATE'.
        ENDIF.
      ENDIF.

      " 4. Search Master Tables ZAGRI_CROP and ZAGRI_CROP_SOIL for Farmer's Requested Crop
      SELECT SINGLE c~crop_name, cs~yield_potential, cs~water_req
        FROM zagri_crop AS c
        INNER JOIN zagri_crop_soil AS cs ON c~crop_id = cs~crop_id
        INTO (@lv_crop, @lv_yield, @lv_water)
        WHERE cs~soil_type_id = @p_stype
          AND c~crop_name      = @p_rcrop
          AND c~season         = @lv_season
          AND c~optimal_ph_min <= @p_ph
          AND c~optimal_ph_max >= @p_ph
          AND cs~suitability   = 'OPTIMAL'.

      IF sy-subrc = 0 AND lv_crop IS NOT INITIAL.
        " --- Found in SAP Master Compatibility Database ---
        lv_source = |SAP Master Compatibility Database (Target Crop: { p_rcrop })|.

        IF p_p < 30 AND p_n < 100.
          lv_fert       = 'DAP + Urea Complex (46% P2O5, 46% N)'.
          lv_num_dosage = '110.00'.
          lv_dose       = '110.0 kg/acre'.
        ELSEIF p_p < 30.
          lv_fert       = 'Single Super Phosphate (SSP 16% P2O5)'.
          lv_num_dosage = '125.00'.
          lv_dose       = '125.0 kg/acre'.
        ELSE.
          lv_fert       = 'NPK 19-19-19 Balanced Formulation'.
          lv_num_dosage = '100.00'.
          lv_dose       = '100.0 kg/acre'.
        ENDIF.

        lv_note = |Verified from ZAGRI_CROP_SOIL. Requested crop { p_rcrop } is optimal for { lv_season } season on { lv_st_name } ({ lv_perm } Permeability). Yield Potential: { lv_yield }, Water Requirement: { lv_water }.|.

      ELSE.
        " --- Dynamic Google Gemini AI Bridge (Zero Hardcoded Rules) ---
        PERFORM call_gemini_client_bridge
          USING
            p_apiurl
            p_reqid
            p_zone
            p_sdate
            p_stype
            p_rcrop
            p_ph
            p_moist
            p_n
            p_p
            p_k
          CHANGING
            ls_ai_res
            lv_err_msg.

        IF lv_err_msg IS NOT INITIAL.
          MESSAGE |Gemini AI Bridge Error: { lv_err_msg }| TYPE 'E'.
          RETURN.
        ENDIF.

        lv_source  = 'Google Gemini Agronomic AI Bridge (Live Dynamic Analysis)'.
        lv_crop    = ls_ai_res-recommended_crop.
        lv_fert    = ls_ai_res-fert_id.
        lv_dose    = |{ ls_ai_res-std_dosage_acre } kg/acre|.
        lv_note    = ls_ai_res-advisory_note.

        " Clean and parse dosage safely for DDIC quantity field
        lv_clean_dose = ls_ai_res-std_dosage_acre.
        REPLACE ALL OCCURRENCES OF ',' IN lv_clean_dose WITH '.'.
        CONDENSE lv_clean_dose NO-GAPS.
        TRY.
            lv_num_dosage = lv_clean_dose.
          CATCH cx_root.
            lv_num_dosage = 0.
        ENDTRY.

        IF ls_ai_res-soil_condition IS NOT INITIAL.
          lv_texture = ls_ai_res-soil_condition.
        ENDIF.
        IF ls_ai_res-season IS NOT INITIAL.
          lv_season  = ls_ai_res-season.
        ENDIF.

      ENDIF.

      " 5. Export / Persist Advisory into ZAGRI_AI_QUEUE Database Table
      CLEAR ls_ai_queue.
      ls_ai_queue-mandt       = sy-mandt.
      ls_ai_queue-req_id      = p_reqid.
      ls_ai_queue-region      = p_zone.
      ls_ai_queue-survey_date = p_sdate.
      ls_ai_queue-soil_type   = p_stype.
      ls_ai_queue-ph_val      = p_ph.
      ls_ai_queue-moisture    = p_moist.
      ls_ai_queue-nitrogen    = p_n.
      ls_ai_queue-phosphorus  = p_p.
      ls_ai_queue-potassium   = p_k.
      ls_ai_queue-status      = 'COMPLETED'.
      ls_ai_queue-season      = lv_season.
      ls_ai_queue-soil_cond   = lv_cond.
      ls_ai_queue-rec_crop    = lv_crop.
      ls_ai_queue-fert_id     = lv_fert.
      ls_ai_queue-dosage      = lv_num_dosage.
      ls_ai_queue-note        = lv_note.

      MODIFY zagri_ai_queue FROM ls_ai_queue.
      IF sy-subrc = 0.
        COMMIT WORK AND WAIT.
        lv_db_status = 'Exported to ZAGRI_AI_QUEUE (Status: COMPLETED)'.
      ELSE.
        lv_db_status = 'Database Insert Error (Check ZAGRI_AI_QUEUE)'.
      ENDIF.

      " 6. Display Result in Modal Dialog
      IF go_dialog IS BOUND.
        go_dialog->free( ).
        CLEAR go_dialog.
      ENDIF.

      CREATE OBJECT go_dialog
        EXPORTING
          top        = 50
          left       = 160
          width      = 820
          height     = 530
          caption    = 'Agronomic Evaluation & Advisory Card'
        EXCEPTIONS
          cntl_error = 1
          OTHERS     = 2.

      SET HANDLER lcl_event_handler=>on_close FOR go_dialog.

      CREATE OBJECT go_html
        EXPORTING
          parent = go_dialog.

      " Register HTML SAPEVENT for the Close button
      CLEAR lt_events.
      ls_event-eventid    = cl_gui_html_viewer=>m_id_sapevent.
      ls_event-appl_event = 'X'.
      APPEND ls_event TO lt_events.
      go_html->set_registered_events( events = lt_events ).
      SET HANDLER lcl_event_handler=>on_sapevent FOR go_html.

      CLEAR lt_html.
      APPEND '<html><head><style>' TO lt_html.
      APPEND 'body { font-family: "Segoe UI", Arial, sans-serif; background: #f4f6f9; margin: 0; padding: 18px; color: #2c3e50; }' TO lt_html.
      APPEND '.card { background: #ffffff; border-radius: 12px; box-shadow: 0 4px 16px rgba(0,0,0,0.08); padding: 22px; border-left: 6px solid #2980b9; }' TO lt_html.
      APPEND '.header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #ecf0f1; padding-bottom: 12px; margin-bottom: 12px; }' TO lt_html.
      APPEND '.title { font-size: 20px; font-weight: 700; color: #1e3d59; }' TO lt_html.
      APPEND '.badge { background: #2980b9; color: white; padding: 5px 12px; border-radius: 20px; font-size: 11px; font-weight: 600; text-transform: uppercase; }' TO lt_html.
      APPEND '.source-tag { font-size: 12px; color: #7f8c8d; font-style: italic; margin-bottom: 12px; }' TO lt_html.
      APPEND '.grid { width: 100%; border-collapse: collapse; margin-top: 6px; margin-bottom: 14px; }' TO lt_html.
      APPEND '.grid td { padding: 8px 10px; font-size: 13px; border-bottom: 1px solid #f1f2f6; }' TO lt_html.
      APPEND '.label { font-weight: 600; color: #7f8c8d; width: 34%; }' TO lt_html.
      APPEND '.value { font-weight: 600; color: #2c3e50; font-size: 14px; }' TO lt_html.
      APPEND '.highlight { color: #d35400; font-weight: 700; }' TO lt_html.
      APPEND '.advisory-box { background: #e8f8f5; border-radius: 8px; border: 1px solid #a3e4d7; padding: 12px; margin-top: 8px; margin-bottom: 16px; }' TO lt_html.
      APPEND '.advisory-title { font-size: 11px; font-weight: 700; color: #16a085; text-transform: uppercase; margin-bottom: 4px; }' TO lt_html.
      APPEND '.advisory-text { font-size: 13px; color: #2c3e50; line-height: 1.45; margin: 0; }' TO lt_html.
      APPEND '.btn-row { text-align: right; }' TO lt_html.
      APPEND '.btn-close { background: #2c3e50; color: #fff; text-decoration: none; padding: 8px 18px; border-radius: 6px; font-size: 12px; font-weight: 600; display: inline-block; }' TO lt_html.
      APPEND '.btn-close:hover { background: #34495e; }' TO lt_html.
      APPEND '</style></head><body>' TO lt_html.

      APPEND '<div class="card">' TO lt_html.
      APPEND '<div class="header">' TO lt_html.
      APPEND |  <div class="title">Crop & Soil Advisory: { p_zone }</div>| TO lt_html.
      APPEND |  <span class="badge">{ lv_season } Season</span>| TO lt_html.
      APPEND '</div>' TO lt_html.
      APPEND |<div class="source-tag"><b>Data Evaluation Source:</b> { lv_source }</div>| TO lt_html.

      APPEND '<table class="grid">' TO lt_html.
      APPEND |  <tr><td class="label">Field Request / Soil ID:</td><td class="value">{ p_reqid } / { p_stype } ({ lv_st_name })</td></tr>| TO lt_html.
      APPEND |  <tr><td class="label">Farmer Requested Crop:</td><td class="value" style="color: #2980b9; font-size: 15px;"><b>{ p_rcrop }</b></td></tr>| TO lt_html.
      APPEND |  <tr><td class="label">Soil Texture / Permeability:</td><td class="value">{ lv_texture } / <b>{ lv_perm }</b></td></tr>| TO lt_html.
      APPEND |  <tr><td class="label">pH & Moisture Condition:</td><td class="value"><span class="highlight">{ lv_cond }</span> (pH { p_ph }, Moisture { p_moist }%)</td></tr>| TO lt_html.
      APPEND |  <tr><td class="label">AI Evaluated / Rec. Crop:</td><td class="value" style="color: #27ae60; font-size: 16px;"><b>{ lv_crop }</b></td></tr>| TO lt_html.
      APPEND |  <tr><td class="label">Targeted Fertilizer:</td><td class="value">{ lv_fert }</td></tr>| TO lt_html.
      APPEND |  <tr><td class="label">Standard Dosage:</td><td class="value">{ lv_dose }</td></tr>| TO lt_html.
      APPEND |  <tr><td class="label">Database Persistence:</td><td class="value"><span style="color: #27ae60; font-weight: 700;">&#10004; { lv_db_status }</span></td></tr>| TO lt_html.
      APPEND '</table>' TO lt_html.

      APPEND '<div class="advisory-box">' TO lt_html.
      APPEND '  <div class="advisory-title">Agronomic Advisory & Nutrient Guidance</div>' TO lt_html.
      APPEND |  <p class="advisory-text">{ lv_note }</p>| TO lt_html.
      APPEND '</div>' TO lt_html.

      APPEND '<div class="btn-row">' TO lt_html.
      APPEND '  <a class="btn-close" href="sapevent:CLOSE_MODAL">Close Advisory</a>' TO lt_html.
      APPEND '</div>' TO lt_html.

      APPEND '</div></body></html>' TO lt_html.

      go_html->load_data(
        IMPORTING
          assigned_url = lv_url
        CHANGING
          data_table   = lt_html ).

      go_html->show_url( url = lv_url ).

      MESSAGE 'Advisory evaluated and exported to ZAGRI_AI_QUEUE successfully.' TYPE 'S'.

  ENDCASE.

*&---------------------------------------------------------------------*
*& Form CALL_GEMINI_CLIENT_BRIDGE
*&---------------------------------------------------------------------*
FORM call_gemini_client_bridge
  USING
    iv_url    TYPE string
    iv_reqid  TYPE zagri_de_reqid
    iv_zone   TYPE char30
    iv_sdate  TYPE sy-datum
    iv_stype  TYPE zagri_de_stype
    iv_rcrop  TYPE zagri_de_cropname
    iv_ph     TYPE zagri_de_ph
    iv_moist  TYPE zagri_de_moist
    iv_n      TYPE i
    iv_p      TYPE i
    iv_k      TYPE i
  CHANGING
    cs_res    TYPE ty_ai_response
    cv_error  TYPE string.

  DATA: lv_temp_dir   TYPE string,
        lv_req_file   TYPE string,
        lv_res_file   TYPE string,
        lv_bat_file   TYPE string,
        lv_log_file   TYPE string,
        lv_json_req   TYPE string,
        lv_json_res   TYPE string,
        lv_err_log    TYPE string,
        lv_line       TYPE string,
        lt_req_tab    TYPE TABLE OF string,
        lt_res_tab    TYPE TABLE OF string,
        lt_bat_tab    TYPE TABLE OF string,
        lv_cmd        TYPE string,
        lv_param      TYPE string,
        lv_sdate_iso  TYPE string,
        lv_ph_str     TYPE string,
        lv_moist_str  TYPE string,
        lv_target_url TYPE string,
        lv_del_rc     TYPE i.

  CLEAR: cs_res, cv_error.

  " Default to 127.0.0.1:8000/predict (direct IPv4 connection)
  IF iv_url IS INITIAL.
    lv_target_url = 'http://127.0.0.1:8000/predict'.
  ELSE.
    lv_target_url = iv_url.
  ENDIF.

  " 1. Format dynamic fields for clean JSON
  lv_sdate_iso = |{ iv_sdate+0(4) }-{ iv_sdate+4(2) }-{ iv_sdate+6(2) }|.

  lv_ph_str = |{ iv_ph }|.
  REPLACE ALL OCCURRENCES OF ',' IN lv_ph_str WITH '.'.
  CONDENSE lv_ph_str NO-GAPS.

  lv_moist_str = |{ iv_moist }|.
  REPLACE ALL OCCURRENCES OF ',' IN lv_moist_str WITH '.'.
  CONDENSE lv_moist_str NO-GAPS.

  " 2. Build JSON Request Payload matching FastAPI SoilSurveyInput
  lv_json_req = '{"request_id":"' && iv_reqid && '",' &&
                '"region":"' && iv_zone && '",' &&
                '"survey_date":"' && lv_sdate_iso && '",' &&
                '"soil_type":"' && iv_stype && '",' &&
                '"req_crop":"' && iv_rcrop && '",' &&
                '"ph_val":' && lv_ph_str && ',' &&
                '"moisture":' && lv_moist_str && ',' &&
                '"nitrogen":' && iv_n && ',' &&
                '"phosphorus":' && iv_p && ',' &&
                '"potassium":' && iv_k && '}'.

  APPEND lv_json_req TO lt_req_tab.

  " 3. Resolve Temp Directory
  cl_gui_frontend_services=>get_temp_directory(
    CHANGING
      temp_dir             = lv_temp_dir
    EXCEPTIONS
      cntl_error           = 1
      error_no_gui         = 2
      not_supported_by_gui = 3
      OTHERS               = 4 ).

  IF lv_temp_dir IS INITIAL.
    lv_temp_dir = 'C:\Temp'.
  ENDIF.

  lv_req_file = lv_temp_dir && '\sap_req_' && sy-uzeit && '.json'.
  lv_res_file = lv_temp_dir && '\sap_gemini_res.json'.
  lv_bat_file = lv_temp_dir && '\run_ai.bat'.
  lv_log_file = lv_temp_dir && '\ai_bridge.log'.

  " 4. Delete old response and log files first so no stale data can ever be read
  cl_gui_frontend_services=>file_delete(
    EXPORTING
      filename = lv_res_file
    CHANGING
      rc       = lv_del_rc
    EXCEPTIONS
      OTHERS   = 1 ).

  cl_gui_frontend_services=>file_delete(
    EXPORTING
      filename = lv_log_file
    CHANGING
      rc       = lv_del_rc
    EXCEPTIONS
      OTHERS   = 1 ).

  " 5. Download request JSON payload
  cl_gui_frontend_services=>gui_download(
    EXPORTING
      filename                  = lv_req_file
      filetype                  = 'DAT'
    CHANGING
      data_tab                  = lt_req_tab
    EXCEPTIONS
      OTHERS                    = 1 ).

  IF sy-subrc <> 0.
    cv_error = 'Unable to write request payload to local client directory.'.
    RETURN.
  ENDIF.

  " 6. Generate run_ai.bat on client PC
  CLEAR lt_bat_tab.
  APPEND '@echo off' TO lt_bat_tab.
  APPEND |echo STARTING AI BRIDGE > "{ lv_log_file }"| TO lt_bat_tab.
  APPEND |"C:\\Windows\\System32\\curl.exe" -s -X POST "{ lv_target_url }" -H "Content-Type: application/json" --data-binary "@{ lv_req_file }" -o "{ lv_res_file }" >> "{ lv_log_file }" 2>&1| TO lt_bat_tab.
  APPEND |echo EXIT_CODE=%ERRORLEVEL% >> "{ lv_log_file }"| TO lt_bat_tab.

  cl_gui_frontend_services=>gui_download(
    EXPORTING
      filename                  = lv_bat_file
      filetype                  = 'DAT'
    CHANGING
      data_tab                  = lt_bat_tab
    EXCEPTIONS
      OTHERS                    = 1 ).

  cl_gui_cfw=>flush( EXCEPTIONS OTHERS = 1 ).

  " 7. Execute run_ai.bat via Windows cmd.exe
  lv_cmd = 'C:\Windows\System32\cmd.exe'.
  lv_param = |/c "{ lv_bat_file }"|.

  cl_gui_frontend_services=>execute(
    EXPORTING
      application            = lv_cmd
      parameter              = lv_param
      synchronous            = 'X'
      minimized              = 'X'
    EXCEPTIONS
      OTHERS                 = 1 ).

  cl_gui_cfw=>flush( EXCEPTIONS OTHERS = 1 ).

  " 8. Read back response JSON from local temp directory (up to 45s for cloud/local)
  DO 45 TIMES.
    CLEAR: lt_res_tab, lv_json_res.
    cl_gui_frontend_services=>gui_upload(
      EXPORTING
        filename                = lv_res_file
        filetype                = 'DAT'
      CHANGING
        data_tab                = lt_res_tab
      EXCEPTIONS
        OTHERS                  = 1 ).

    IF sy-subrc = 0 AND lt_res_tab IS NOT INITIAL.
      LOOP AT lt_res_tab INTO lv_line.
        lv_json_res = lv_json_res && lv_line.
      ENDLOOP.

      IF lv_json_res IS NOT INITIAL AND
         ( lv_json_res CS 'recommended_crop' OR lv_json_res CS 'error' ).
        EXIT.
      ENDIF.
    ENDIF.

    WAIT UP TO 1 SECONDS.
  ENDDO.

  " 9. If response is empty, read the execution log to diagnose the exact problem
  IF lv_json_res IS INITIAL.
    CLEAR: lt_res_tab, lv_err_log.
    cl_gui_frontend_services=>gui_upload(
      EXPORTING
        filename                = lv_log_file
        filetype                = 'DAT'
      CHANGING
        data_tab                = lt_res_tab
      EXCEPTIONS
        OTHERS                  = 1 ).

    LOOP AT lt_res_tab INTO lv_line.
      lv_err_log = lv_err_log && ' ' && lv_line.
    ENDLOOP.

    IF lv_err_log IS NOT INITIAL.
      cv_error = |AI Execution Log: { lv_err_log }|.
    ELSE.
      cv_error = 'AI Bridge script failed to launch. Ensure "python main.py" is running on port 8000.'.
    ENDIF.
    RETURN.
  ENDIF.

  IF lv_json_res CS 'Unable to connect' OR lv_json_res CS 'No connection could be made'.
    cv_error = |Connection refused at { lv_target_url }. Ensure Python server is running on port 8000.|.
    RETURN.
  ENDIF.

  " 10. Deserialize JSON into ABAP structure
  /ui2/cl_json=>deserialize(
    EXPORTING
      json        = lv_json_res
      pretty_name = /ui2/cl_json=>pretty_mode-none
    CHANGING
      data        = cs_res ).

  IF cs_res-recommended_crop IS INITIAL.
    cv_error = |AI Model Response Error: { lv_json_res }|.
  ENDIF.

ENDFORM.
