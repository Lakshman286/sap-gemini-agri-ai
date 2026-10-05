"""
Production-style FastAPI backend acting as an AI bridge between SAP ABAP and Google Gemini.
Agricultural Soil Testing and Fertilizer Recommendation Service.

IMPORTANT:
- No hardcoded recommendations, crops, fertilizers, dosages, or rule-based IF/ELSE fallbacks.
- Dynamic analysis performed strictly by Google Gemini based on field survey parameters.
- Validated with Pydantic for end-to-end type safety and compliance with SAP ABAP.
"""

import logging
import os
import re
import sys
from datetime import date
from typing import Any, Dict

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from google import genai
from google.genai import errors, types
from pydantic import BaseModel, Field, field_validator
import uvicorn

# Load environment variables from .env file
load_dotenv()

# ==============================================================================
# LOGGING CONFIGURATION
# ==============================================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [SAP-AI-BRIDGE] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("sap_gemini_bridge")

# ==============================================================================
# PYDANTIC DATA MODELS
# ==============================================================================

class SoilSurveyInput(BaseModel):
    """
    Input payload received from SAP ABAP report containing dynamic field-survey data.
    """
    request_id: str = Field(
        ...,
        description="Unique SAP survey request identifier",
        min_length=1,
        examples=["REQ-2026-001"]
    )
    region: str = Field(
        ...,
        description="Geographical zone / region of the survey",
        min_length=1,
        examples=["Deccan Plateau"]
    )
    survey_date: str = Field(
        ...,
        description="Date of the soil survey in YYYY-MM-DD format",
        examples=["2026-06-15"]
    )
    soil_type: str = Field(
        ...,
        description="Soil type / texture classification from the field",
        min_length=1,
        examples=["Black Cotton Soil"]
    )
    ph_val: float = Field(
        ...,
        description="Soil pH value on standard 0-14 scale",
        ge=0.0,
        le=14.0,
        examples=[7.2]
    )
    moisture: float = Field(
        ...,
        description="Soil moisture level percentage (0.0 to 100.0%)",
        ge=0.0,
        le=100.0,
        examples=[24.5]
    )
    nitrogen: float = Field(
        ...,
        description="Available Nitrogen (N) value (e.g. kg/ha or rating index)",
        ge=0.0,
        examples=[140.0]
    )
    phosphorus: float = Field(
        ...,
        description="Available Phosphorus (P) value (e.g. kg/ha or rating index)",
        ge=0.0,
        examples=[22.0]
    )
    potassium: float = Field(
        ...,
        description="Available Potassium (K) value (e.g. kg/ha or rating index)",
        ge=0.0,
        examples=[310.0]
    )
    req_crop: str = Field(
        default="",
        description="Farmer's target / requested crop to cultivate (or evaluate)",
        examples=["Paddy", "Cotton", "Groundnut", "Wheat"]
    )

    @field_validator("survey_date")
    @classmethod
    def validate_date_format(cls, v: str) -> str:
        """Validate that survey_date conforms to YYYY-MM-DD and is a real calendar date."""
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", v):
            raise ValueError("survey_date must be formatted as YYYY-MM-DD")
        try:
            date.fromisoformat(v)
        except ValueError:
            raise ValueError("survey_date must be a valid calendar date")
        return v


class AIRecommendationResponse(BaseModel):
    """
    Structured recommendation response returned to SAP ABAP.
    Conforms strictly to the required SAP interface format.
    """
    season: str = Field(
        ...,
        description="Agricultural cropping season dynamically determined from region and survey date"
    )
    soil_condition: str = Field(
        ...,
        description="Soil condition dynamically determined from pH, moisture, and soil classification"
    )
    recommended_crop: str = Field(
        ...,
        description="Recommended crop dynamically deduced from soil properties, nutrient status, and season"
    )
    fert_id: str = Field(
        ...,
        description="Optimal fertilizer formulation/grade identifier dynamically determined to balance nutrient deficiencies"
    )
    std_dosage_acre: float = Field(
        ...,
        description="Standard dosage per acre in kg or standard units dynamically calculated for the recommendation"
    )
    advisory_note: str = Field(
        ...,
        description="Practical agronomic advisory and safety guidance, explicitly framed as decision-support guidance"
    )


class HealthResponse(BaseModel):
    """Health check response model."""
    status: str = "ok"


# ==============================================================================
# FASTAPI APPLICATION SETUP
# ==============================================================================
app = FastAPI(
    title="SAP ABAP - Google Gemini Agricultural Recommendation Bridge",
    description=(
        "Production-style AI bridge between SAP ABAP soil testing reports and Google Gemini. "
        "Provides 100% dynamic, data-driven agronomic recommendations without hardcoded fallback rules."
    ),
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# ==============================================================================
# EXCEPTION HANDLERS
# ==============================================================================
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """
    Custom handler for SAP payload validation errors.
    Returns clear, structured diagnostics without masking input defects.
    """
    encoded_errors = jsonable_encoder(exc.errors())
    logger.warning(f"Invalid SAP request payload rejected: {encoded_errors}")
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={
            "error": "Invalid SAP request payload",
            "details": encoded_errors
        }
    )


# ==============================================================================
# GEMINI CLIENT HELPER
# ==============================================================================
def get_gemini_client() -> genai.Client:
    """
    Initializes and returns a Google GenAI Client using the GEMINI_API_KEY.
    Raises HTTPException(500) if the key is missing or unconfigured.
    """
    api_key = os.getenv("GEMINI_API_KEY", "").strip()
    if not api_key or api_key == "YOUR_GEMINI_API_KEY":
        logger.error("GEMINI_API_KEY is not configured or contains placeholder text.")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=(
                "Gemini API key is not configured. Please set the GEMINI_API_KEY "
                "environment variable in your .env file or system environment."
            ),
        )

    try:
        # Convert seconds to milliseconds for Google GenAI HttpOptions
        timeout_ms = int(float(os.getenv("GEMINI_TIMEOUT_SECONDS", "30.0")) * 1000)
    except ValueError:
        timeout_ms = 30000

    return genai.Client(
        api_key=api_key,
        http_options=types.HttpOptions(timeout=timeout_ms)
    )


# ==============================================================================
# PROMPT CONSTRUCTION
# ==============================================================================
GEMINI_SYSTEM_INSTRUCTION = (
    "You are an expert agronomic AI decision-support system integrated into an SAP ABAP enterprise agriculture platform.\n"
    "Your objective is to perform comprehensive, dynamic agronomic analysis on dynamic soil survey test inputs and generate "
    "structured, accurate crop and fertilizer recommendations.\n\n"
    "CRITICAL SCIENTIFIC & SAFETY GUIDELINES:\n"
    "1. Completely Dynamic: Do NOT use hardcoded templates, preset crop names, or static fertilizer rules. Every output "
    "must be dynamically evaluated from the supplied survey parameters (Region, Survey Date, Soil Type, pH, Moisture, N, P, K, and Farmer's Requested Crop if provided).\n"
    "2. Agricultural Season: Dynamically determine the agricultural cropping season from the specific region's agro-climatic "
    "calendar and the survey date (e.g. Kharif, Rabi, Zaid, Spring, Autumn, Dry/Wet season).\n"
    "3. Soil pH & Condition: Dynamically characterize the soil condition based on exact pH (acidic, neutral, alkaline), "
    "moisture, and soil texture.\n"
    "4. Farmer Requested Crop & Crop Recommendation: When a farmer specifies a requested crop (req_crop), evaluate its agronomic "
    "viability against the soil type, pH, moisture, and prevailing season. If suitable or viable with corrective soil conditioning, "
    "confirm it in recommended_crop and formulate fertilizer specifically for this crop. If severely unviable (e.g. salinity or water requirements incompatible), "
    "explain why clearly in advisory_note and specify the most viable alternative crop in recommended_crop.\n"
    "5. Fertilizer Formulation & Dosage: Determine the optimal fertilizer formulation/code (fert_id) to address specific NPK "
    "deficiencies for the target crop, along with a standard dosage per acre (numeric float in kg/acre).\n"
    "6. Safety & Advisory Nature: Treat all recommendations strictly as agronomic advisory guidance. In advisory_note, detail specific "
    "suitability assessment for the requested crop, basal vs top-dressing split schedules, and soil conditioning precautions.\n"
    "7. Data Sufficiency: If the field data is anomalous, conflicting, or insufficient to formulate a reliable recommendation, "
    "provide a clear advisory note explaining the data limitations and specifying necessary supplemental field tests rather than fabricating data."
)


def build_user_prompt(survey: SoilSurveyInput) -> str:
    """
    Constructs the dynamic prompt for Gemini using field survey parameters from SAP.
    """
    req_crop_line = f"- Farmer Requested Crop: {survey.req_crop}\n" if survey.req_crop else "- Farmer Requested Crop: Not specified (suggest best crop dynamically)\n"
    return (
        f"Dynamic Field Survey Soil Test Data received from SAP ABAP:\n"
        f"- Request ID: {survey.request_id}\n"
        f"- Region / Zone: {survey.region}\n"
        f"- Survey Date: {survey.survey_date}\n"
        f"- Soil Type: {survey.soil_type}\n"
        f"- Soil pH: {survey.ph_val}\n"
        f"- Soil Moisture (%): {survey.moisture}\n"
        f"- Available Nitrogen (N): {survey.nitrogen}\n"
        f"- Available Phosphorus (P): {survey.phosphorus}\n"
        f"- Available Potassium (K): {survey.potassium}\n"
        f"{req_crop_line}\n"
        f"Please analyze these parameters dynamically and return the structured recommendation conforming to the schema:\n"
        f"- season: Agricultural season for this region and survey date\n"
        f"- soil_condition: Agronomic condition derived from pH, moisture, and soil classification\n"
        f"- recommended_crop: Optimal or validated crop for this field\n"
        f"- fert_id: Optimal fertilizer grade/formulation code to balance nutrient deficits for this crop\n"
        f"- std_dosage_acre: Standard recommended dosage per acre (numeric value in kg/acre)\n"
        f"- advisory_note: Agronomic advisory, requested crop suitability analysis, application precautions, and safety guidance."
    )


# ==============================================================================
# API ENDPOINTS
# ==============================================================================

@app.get(
    "/health",
    response_model=HealthResponse,
    tags=["System"],
    summary="Health check endpoint for SAP ABAP and infrastructure monitoring",
)
async def health_check() -> HealthResponse:
    """
    Verifies that the FastAPI bridge service is up and operational.
    """
    return HealthResponse(status="ok")


@app.post(
    "/predict",
    response_model=AIRecommendationResponse,
    status_code=status.HTTP_200_OK,
    tags=["Agronomic Recommendation"],
    summary="Generate dynamic crop and fertilizer recommendation from SAP soil survey",
    responses={
        200: {
            "description": "Dynamic agronomic recommendation generated successfully",
            "model": AIRecommendationResponse,
        },
        422: {"description": "Invalid SAP request payload or missing fields"},
        500: {"description": "Server configuration error (e.g. missing Gemini API key)"},
        502: {"description": "Google Gemini API failure or schema validation error"},
        504: {"description": "Google Gemini API request timeout"},
    },
)
async def predict_soil_recommendation(
    survey: SoilSurveyInput
) -> AIRecommendationResponse:
    """
    Receives dynamic field-survey data from SAP ABAP, submits it to Google Gemini with
    structured JSON output enforcement, validates the AI response against Pydantic models,
    and returns the structured recommendation to SAP ABAP.
    """
    # 1. Log incoming request details (never logging sensitive credentials)
    logger.info(
        f"[{survey.request_id}] Request received | Region: {survey.region} | "
        f"Date: {survey.survey_date} | Soil: {survey.soil_type} | pH: {survey.ph_val} | "
        f"Moisture: {survey.moisture}% | N: {survey.nitrogen}, P: {survey.phosphorus}, K: {survey.potassium} | "
        f"Requested Crop: {survey.req_crop or 'None'}"
    )

    # 2. Retrieve Gemini client
    client = get_gemini_client()
    model_name = os.getenv("GEMINI_MODEL", "gemini-3.1-flash-lite").strip()

    # 3. Construct dynamic prompt and structured configuration
    user_prompt = build_user_prompt(survey)
    config = types.GenerateContentConfig(
        system_instruction=GEMINI_SYSTEM_INSTRUCTION,
        response_mime_type="application/json",
        response_schema=AIRecommendationResponse,
        automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
        temperature=0.2,
    )

    # 4. Invoke Gemini API asynchronously
    logger.info(f"[{survey.request_id}] Gemini request started | Model: {model_name}")
    try:
        response = await client.aio.models.generate_content(
            model=model_name,
            contents=user_prompt,
            config=config,
        )
    except errors.APIError as api_err:
        err_msg = getattr(api_err, "message", str(api_err))
        err_code = getattr(api_err, "code", status.HTTP_502_BAD_GATEWAY)
        if err_code not in (500, 502, 503, 504):
            err_code = status.HTTP_502_BAD_GATEWAY
        logger.error(f"[{survey.request_id}] Gemini API Error ({err_code}): {err_msg}", exc_info=True)
        raise HTTPException(
            status_code=err_code,
            detail=f"Google Gemini API error: {err_msg}",
        )
    except (TimeoutError, httpx.TimeoutException) as timeout_err:
        logger.error(f"[{survey.request_id}] Gemini API timeout: {timeout_err}")
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="Google Gemini API request timed out. Please retry.",
        )
    except HTTPException:
        raise
    except Exception as exc:
        logger.error(f"[{survey.request_id}] Unexpected error during Gemini call: {exc}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Internal bridge error during Gemini processing: {str(exc)}",
        )

    logger.info(f"[{survey.request_id}] Gemini response received")

    # 5. Extract and validate structured AI response
    raw_response_text = response.text
    if not raw_response_text:
        logger.error(f"[{survey.request_id}] Gemini returned an empty response body.")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Google Gemini returned an empty response.",
        )

    try:
        recommendation = AIRecommendationResponse.model_validate_json(raw_response_text)
    except Exception as val_err:
        logger.error(
            f"[{survey.request_id}] AI response failed Pydantic schema validation: {val_err}\n"
            f"Raw AI payload: {raw_response_text}"
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"AI model response failed schema validation: {str(val_err)}",
        )

    # 6. Log request completion
    logger.info(
        f"[{survey.request_id}] Request completed successfully | Season: {recommendation.season} | "
        f"Crop: {recommendation.recommended_crop} | Fert ID: {recommendation.fert_id} | "
        f"Dosage: {recommendation.std_dosage_acre} kg/acre"
    )

    return recommendation


# ==============================================================================
# MAIN ENTRYPOINT
# ==============================================================================
if __name__ == "__main__":
    host = os.getenv("HOST", "0.0.0.0")
    try:
        port = int(os.getenv("PORT", "8000"))
    except ValueError:
        port = 8000

    logger.info(f"Starting SAP-Gemini AI Bridge server on {host}:{port}...")
    uvicorn.run("main:app", host=host, port=port, reload=False)
