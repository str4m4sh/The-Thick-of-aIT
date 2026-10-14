import os
import uvicorn
import traceback
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any
from agents import AgentTeam
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(
    title="The Thick of aIT",
    description="H.M. Government - Department of Social Affairs and Information Technology (DoSAC). "
                "Featuring Terri (Routing), Stewart (Strategy & Dialogue), Oliver (Architecture), "
                "Jamie (Development), and Malcolm Tucker (QA & Scots Swearing).",
    version="2.0.0"
)

team = AgentTeam()

class PromptRequest(BaseModel):
    prompt: str = Field(..., json_schema_extra={"example": "Write a python function to compute fibonacci numbers and test it"})

class ChatRequest(BaseModel):
    prompt: str = Field(..., json_schema_extra={"example": "Stewart, explain how Docker namespaces work in layman terms"})
    history: Optional[List[Dict[str, str]]] = Field(default=None)

@app.get("/health")
async def health_check():
    return {
        "status": "order_in_the_house",
        "department": "DoSAC (Department of Social Affairs and Information Technology)",
        "chat_model": team.chat_model,
        "code_model": team.code_model
    }

@app.post("/v1/process")
async def process_request(request: PromptRequest):
    """
    Unified Cabinet Dispatch:
    Terri routes the inquiry. If conversational, Stewart takes it. If technical, Oliver plans, Jamie develops, and Malcolm assesses.
    """
    try:
        return await team.run_pipeline(request.prompt)
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e) or type(e).__name__)

@app.post("/v1/chat")
async def chat_endpoint(request: ChatRequest):
    """Stewart Pearson's Office: Translating technical complexities into digestible modern wisdom."""
    try:
        reply = await team.conversation(request.prompt, request.history)
        return {
            "department": "DoSAC - Directorate of Strategy",
            "agent": "Stewart Pearson",
            "response": reply
        }
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e) or type(e).__name__)

@app.post("/v1/code")
async def code_endpoint(request: PromptRequest):
    """
    The Policy & Code Engine:
    Oliver plans, Jamie builds, Docker sandboxes, and Malcolm Tucker unleashes Scots QA review.
    """
    try:
        plan = await team.plan(request.prompt)
        code = await team.develop(request.prompt, plan)
        test_review = await team.review_and_test(code)

        if not test_review["sandbox"]["success"]:
            feedback = f"Malcolm Tucker's rage: {test_review['review']}\nError log: {test_review['sandbox']['stderr']}"
            code = await team.develop(request.prompt, plan, feedback=feedback)
            test_review = await team.review_and_test(code)

        return {
            "department": "DoSAC Policy & Technical Enforcement",
            "oliver_reeder_plan": plan,
            "jamie_mcdonald_code": code,
            "sandbox_execution": test_review["sandbox"],
            "malcolm_tucker_verdict": test_review["review"]
        }
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e) or type(e).__name__)

if __name__ == "__main__":
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", 8000))
    uvicorn.run("server:app", host=host, port=port, reload=False)
