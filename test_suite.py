"""
Unit and integration tests for SAP ABAP - Google Gemini Agricultural Bridge.
Tests health check, payload validation, and Gemini response parsing.
"""

from unittest.mock import AsyncMock, MagicMock, patch
from fastapi.testclient import TestClient
from main import app, SoilSurveyInput, AIRecommendationResponse

client = TestClient(app)


def test_health_endpoint():
    """Verify that GET /health returns 200 OK with {'status': 'ok'}."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_predict_missing_fields_validation():
    """Verify that incomplete SAP requests are rejected with HTTP 422."""
    response = client.post("/predict", json={"request_id": "REQ-001"})
    assert response.status_code == 422
    data = response.json()
    assert "details" in data
    assert data["error"] == "Invalid SAP request payload"


def test_predict_invalid_date_validation():
    """Verify that invalid dates (e.g. non-existent calendar date) fail validation."""
    invalid_payload = {
        "request_id": "REQ-INVALID-DATE",
        "region": "Coastal Zone",
        "survey_date": "2026-02-31",  # Invalid date
        "soil_type": "Clay",
        "ph_val": 6.5,
        "moisture": 30.0,
        "nitrogen": 100.0,
        "phosphorus": 20.0,
        "potassium": 150.0,
    }
    response = client.post("/predict", json=invalid_payload)
    assert response.status_code == 422


def test_predict_successful_gemini_integration():
    """Verify that structured Gemini output is validated and returned to SAP."""
    mock_gemini_response = MagicMock()
    mock_gemini_response.text = (
        '{"season": "Rabi", '
        '"soil_condition": "Moderately alkaline alluvial soil with balanced moisture", '
        '"recommended_crop": "Wheat (Triticum aestivum)", '
        '"fert_id": "FERT-NPK-12-32-16", '
        '"std_dosage_acre": 55.0, '
        '"advisory_note": "Apply basal dose of phosphatic fertilizer before sowing. '
        'Split nitrogen into two vegetative applications. Advisory guidance only; test local salinity."}'
    )

    with patch("main.get_gemini_client") as mock_get_client:
        mock_client = MagicMock()
        mock_client.aio.models.generate_content = AsyncMock(return_value=mock_gemini_response)
        mock_get_client.return_value = mock_client

        test_payload = {
            "request_id": "SAP-FIELD-999",
            "region": "Indo-Gangetic Plain",
            "survey_date": "2026-11-05",
            "soil_type": "Alluvial Loam",
            "ph_val": 7.6,
            "moisture": 28.0,
            "nitrogen": 135.0,
            "phosphorus": 24.0,
            "potassium": 210.0,
        }

        response = client.post("/predict", json=test_payload)
        assert response.status_code == 200
        data = response.json()
        assert data["season"] == "Rabi"
        assert data["recommended_crop"] == "Wheat (Triticum aestivum)"
        assert data["fert_id"] == "FERT-NPK-12-32-16"
        assert data["std_dosage_acre"] == 55.0
        assert "advisory_note" in data
        assert "soil_condition" in data


def test_predict_gemini_schema_mismatch_fails_gracefully():
    """Verify that if Gemini returns invalid schema, it returns HTTP 502 without fake fallbacks."""
    mock_bad_response = MagicMock()
    # Response missing required fields or having wrong types
    mock_bad_response.text = '{"some_unrelated_field": "test"}'

    with patch("main.get_gemini_client") as mock_get_client:
        mock_client = MagicMock()
        mock_client.aio.models.generate_content = AsyncMock(return_value=mock_bad_response)
        mock_get_client.return_value = mock_client

        test_payload = {
            "request_id": "SAP-FIELD-888",
            "region": "Coastal Zone",
            "survey_date": "2026-07-20",
            "soil_type": "Sandy Clay",
            "ph_val": 6.2,
            "moisture": 45.0,
            "nitrogen": 80.0,
            "phosphorus": 15.0,
            "potassium": 120.0,
        }

        response = client.post("/predict", json=test_payload)
        assert response.status_code == 502
        assert "failed schema validation" in response.json()["detail"]


def test_predict_with_farmer_requested_crop():
    """Verify that requests specifying farmer's target crop (req_crop) are processed properly."""
    mock_gemini_response = MagicMock()
    mock_gemini_response.text = (
        '{"season": "Kharif", '
        '"soil_condition": "Heavy clayey soil with high moisture retention", '
        '"recommended_crop": "Paddy (Wetland Rice)", '
        '"fert_id": "FERT-NPK-17-17-17", '
        '"std_dosage_acre": 120.0, '
        '"advisory_note": "Farmer requested Paddy is well-suited for clay soil. Apply zinc sulphate and split nitrogen."}'
    )

    with patch("main.get_gemini_client") as mock_get_client:
        mock_client = MagicMock()
        mock_client.aio.models.generate_content = AsyncMock(return_value=mock_gemini_response)
        mock_get_client.return_value = mock_client

        test_payload = {
            "request_id": "SAP-FIELD-REQ-CROP",
            "region": "Delta Zone",
            "survey_date": "2026-06-20",
            "soil_type": "Clay",
            "req_crop": "Paddy",
            "ph_val": 6.8,
            "moisture": 35.0,
            "nitrogen": 110.0,
            "phosphorus": 18.0,
            "potassium": 190.0,
        }

        response = client.post("/predict", json=test_payload)
        assert response.status_code == 200
        data = response.json()
        assert data["season"] == "Kharif"
        assert data["recommended_crop"] == "Paddy (Wetland Rice)"
        assert data["fert_id"] == "FERT-NPK-17-17-17"
        assert data["std_dosage_acre"] == 120.0
        assert "Farmer requested Paddy" in data["advisory_note"]


if __name__ == "__main__":
    test_health_endpoint()
    test_predict_missing_fields_validation()
    test_predict_invalid_date_validation()
    test_predict_successful_gemini_integration()
    test_predict_gemini_schema_mismatch_fails_gracefully()
    test_predict_with_farmer_requested_crop()
    print("All unit and integration tests passed successfully!")
