# SAP ABAP - Google Gemini Agricultural Soil Testing & Fertilizer Recommendation Bridge

A production-grade Python FastAPI backend acting as an intelligent, real-time AI bridge between **SAP ABAP** enterprise agriculture reports and **Google Gemini**.

---

## 🏛️ Architecture Flow

```
+--------------------------------------------------------+
|                   SAP ABAP Report                      |
| (Dynamic field survey inputs: N, P, K, pH, Moisture...) |
+--------------------------------------------------------+
                           |
            HTTP POST JSON | /predict
                           v
+--------------------------------------------------------+
|                  Python FastAPI Server                 |
|   - Pydantic schema validation (SoilSurveyInput)        |
|   - Dynamic prompt construction                        |
+--------------------------------------------------------+
                           |
      Asynchronous GenAI   | Structured JSON Output
      google-genai SDK     | (response_schema)
                           v
+--------------------------------------------------------+
|                     Google Gemini                      |
|   - Dynamic season & soil condition analysis           |
|   - Crop & fertilizer recommendation                   |
|   - Agronomic advisory & safety precautions            |
+--------------------------------------------------------+
                           |
      Structured Output    | Validated JSON
                           v
+--------------------------------------------------------+
|                  Python FastAPI Server                 |
|   - Pydantic schema validation (AIRecommendationResponse)|
|   - Structured logging (Request ID, Region, Status)    |
+--------------------------------------------------------+
                           |
        HTTP JSON Response | 200 OK
                           v
+--------------------------------------------------------+
|                   SAP ABAP Report                      |
|         (Processes dynamic recommendation)             |
+--------------------------------------------------------+
```

---

## 🚫 Zero Hardcoding Guarantee

This backend contains **NO hardcoded agronomic rules or mock data**:
- ❌ NO hardcoded crop names (e.g., `"Groundnut"`, `"Wheat"`, `"SIMULATED HYBRID CROP"`)
- ❌ NO hardcoded fertilizer names, codes, or IDs (e.g., `"NPK-10-26-26"`, `"MOCK-NPK"`)
- ❌ NO hardcoded dosages, NPK thresholds, moisture levels, or pH ranges
- ❌ NO static `IF/ELSE` rule engines
- ❌ NO fallback mock recommendations on failure (errors return meaningful HTTP 500/502/504 status codes)

All recommendations are derived dynamically by Google Gemini from the field data sent by SAP ABAP.

---

## 📁 Project Structure

```
sap_laksh/
├── main.py              # FastAPI server, Pydantic schemas, and Gemini AI bridge
├── requirements.txt     # Python dependencies
├── .env.example         # Environment template
├── .gitignore           # Ignores .env and cache
├── test_suite.py        # Automated test suite (health, validation, mock integration)
└── README.md            # Documentation and setup guide
```

---

## 🚀 Setup & Installation

### 1. Install Dependencies
```bash
pip install -r requirements.txt
```

### 2. Configure Environment
Copy the `.env.example` file to `.env`:
```bash
cp .env.example .env
```
*(On Windows PowerShell: `Copy-Item .env.example .env`)*

Open `.env` and configure your Google Gemini API key:
```env
GEMINI_API_KEY=your_actual_gemini_api_key_here
GEMINI_MODEL=gemini-3.8-flash
HOST=0.0.0.0
PORT=8000
GEMINI_TIMEOUT_SECONDS=30.0
```

> **Note:** Never commit the `.env` file or share your API key in source code.

---

## 🏃 Running the Application

Start the backend server on `0.0.0.0:8000`:
```bash
python main.py
```

The server will be reachable at:
- **Base URL:** `http://localhost:8000` (or `http://<server-ip>:8000` from SAP)
- **Interactive Swagger Documentation:** `http://localhost:8000/docs`
- **ReDoc Documentation:** `http://localhost:8000/redoc`

---

## 🩺 Health Check Endpoint

### `GET /health`
Used by SAP ABAP or monitoring systems to verify that the service is running.

**Response:**
```json
{
  "status": "ok"
}
```

---

## 🌾 Recommendation Endpoint

### `POST /predict`

### 1. Request Payload Schema (`SoilSurveyInput`)

| Field | Type | Description | Constraints |
| :--- | :--- | :--- | :--- |
| `request_id` | `string` | Unique SAP request identifier | Non-empty |
| `region` | `string` | Region / agro-climatic zone | Non-empty |
| `survey_date` | `string` | Field survey date | Format: `YYYY-MM-DD` |
| `soil_type` | `string` | Soil classification / texture | Non-empty |
| `req_crop` | `string` | Farmer's requested / target crop | Optional (e.g. `Paddy`, `Cotton`) |
| `ph_val` | `float` | Soil pH level | `0.0` to `14.0` |
| `moisture` | `float` | Soil moisture percentage | `0.0` to `100.0` |
| `nitrogen` | `float` | Available Nitrogen (N) | `>= 0.0` |
| `phosphorus` | `float` | Available Phosphorus (P) | `>= 0.0` |
| `potassium` | `float` | Available Potassium (K) | `>= 0.0` |

### 2. Example Test Request (TEST INPUT ONLY)

> ⚠️ **Notice:** The following JSON is an example test payload for validation only. It is not hardcoded anywhere in the codebase.

```json
{
  "request_id": "SAP-FIELD-2026-001",
  "region": "Indo-Gangetic Alluvial Plain",
  "survey_date": "2026-10-25",
  "soil_type": "Alluvial Loam",
  "req_crop": "Wheat",
  "ph_val": 7.3,
  "moisture": 34.5,
  "nitrogen": 130.0,
  "phosphorus": 20.0,
  "potassium": 260.0
}
```

### 3. Response Schema (`AIRecommendationResponse`)

Validated with Pydantic and returned in structured JSON format:

```json
{
  "season": "Rabi",
  "soil_condition": "Neutral to slightly alkaline alluvial loam with adequate moisture",
  "recommended_crop": "Wheat",
  "fert_id": "FERT-NPK-12-32-16",
  "std_dosage_acre": 50.0,
  "advisory_note": "Farmer requested Wheat is highly suitable for this alluvial loam. Apply phosphorus as basal dressing during sowing. Split nitrogen into two top-dressings with first and second irrigations. Decision-support advisory only; verify local salinity and certified seed varieties before application."
}
```

---

## 🧪 Testing with cURL / PowerShell

### cURL
```bash
curl -X POST "http://localhost:8000/predict" \
     -H "Content-Type: application/json" \
     -d '{
       "request_id": "SAP-FIELD-2026-001",
       "region": "Indo-Gangetic Alluvial Plain",
       "survey_date": "2026-10-25",
       "soil_type": "Alluvial Loam",
       "req_crop": "Wheat",
       "ph_val": 7.3,
       "moisture": 34.5,
       "nitrogen": 130.0,
       "phosphorus": 20.0,
       "potassium": 260.0
     }'
```

### PowerShell
```powershell
$body = @{
    request_id   = "SAP-FIELD-2026-001"
    region       = "Indo-Gangetic Alluvial Plain"
    survey_date  = "2026-10-25"
    soil_type    = "Alluvial Loam"
    req_crop     = "Wheat"
    ph_val       = 7.3
    moisture     = 34.5
    nitrogen     = 130.0
    phosphorus   = 20.0
    potassium    = 260.0
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8000/predict" -Method Post -ContentType "application/json" -Body $body
```

---

## ⚠️ Error Handling & Status Codes

| HTTP Status | Meaning | Scenario |
| :--- | :--- | :--- |
| **`200 OK`** | Success | Recommendation generated and validated against Pydantic schema |
| **`422 Unprocessable Entity`** | Invalid SAP Request | Missing fields, invalid date format, or out-of-range numerical values |
| **`500 Internal Server Error`** | Server / Configuration | Missing `GEMINI_API_KEY` or unexpected internal exception |
| **`502 Bad Gateway`** | Gemini Service Failure | Google Gemini API error or AI response schema violation |
| **`504 Gateway Timeout`** | Upstream Timeout | Gemini API request exceeded configured timeout limit |

---

## 🔍 Automated Test Suite

To run the automated validation tests:
```bash
python test_suite.py
```
This tests:
1. Health check endpoint status
2. Missing payload rejection (HTTP 422)
3. Invalid calendar date validation (HTTP 422)
4. Gemini structured JSON response parsing (HTTP 200)
5. Gemini schema mismatch rejection without fallback mocks (HTTP 502)
