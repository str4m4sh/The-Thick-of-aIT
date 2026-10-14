import os
import re
import json
import httpx
from typing import Dict, Any, List, Optional
from sandbox import run_in_sandbox

LLM_BASE_URL = os.getenv("LLM_BASE_URL", "http://localhost:11434/v1")
LLM_API_KEY = os.getenv("LLM_API_KEY", "ollama")
CHAT_MODEL = os.getenv("CHAT_MODEL", "llama3.2:3b")
CODE_MODEL = os.getenv("CODE_MODEL", "qwen2.5-coder:3b")

async def call_llm(messages: List[Dict[str, str]], model: str, temperature: float = 0.3) -> str:
    headers = {
        "Authorization": f"Bearer {LLM_API_KEY}",
        "Content-Type": "application/json"
    }
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "stream": False
    }

    async with httpx.AsyncClient(timeout=180.0) as client:
        response = await client.post(f"{LLM_BASE_URL.rstrip('/')}/chat/completions", headers=headers, json=payload)
        response.raise_for_status()
        data = response.json()
        return data["choices"][0]["message"]["content"]


def extract_python_code(text: str) -> str:
    match = re.search(r"```python\s*(.*?)\s*```", text, re.DOTALL | re.IGNORECASE)
    if match:
        return match.group(1).strip()
    match = re.search(r"```\s*(.*?)\s*```", text, re.DOTALL)
    if match:
        return match.group(1).strip()
    return text.strip()


class AgentTeam:
    def __init__(self):
        self.chat_model = CHAT_MODEL
        self.code_model = CODE_MODEL

    # Agent 1: Terri Coverley (The Polite English Civil Servant / Router)
    async def route(self, user_prompt: str) -> str:
        prompt = (
            "You are Terri Coverley, Head of Press at the Department of Social Affairs and Citizenship (DoSAC). "
            "You are terribly polite, quintessential English civil service, slightly anxious about PR disasters, "
            "and eager to process paper properly. Categorize this incoming inquiry into either 'chat' or 'code'.\n"
            "- 'code': The user requires software development, script writing, algorithms, or technical debugging.\n"
            "- 'chat': General conversation, explanations, greetings, or ministerial policy queries.\n"
            "Respond ONLY with one single word: 'chat' or 'code'."
        )
        messages = [
            {"role": "system", "content": prompt},
            {"role": "user", "content": user_prompt}
        ]
        decision = await call_llm(messages, model=self.chat_model, temperature=0.0)
        return "code" if "code" in decision.lower() else "chat"

    # Agent 2: Stewart Pearson (Director of Strategy / Explaining tech to laymen)
    async def conversation(self, user_prompt: str, history: Optional[List[Dict[str, str]]] = None) -> str:
        prompt = (
            "You are Stewart Pearson, Director of Strategy and communications guru. You wear linen jackets and speak "
            "with a modern, calm, visionary consulting style ('let's de-silo the narrative', 'visualise the concept space'). "
            "Crucially, you excel at explaining intricate technical details to completely non-technical people with illuminating, "
            "accessible metaphors without condescension. Always maintain Stewart Pearson's calm, modern, organic vibe."
        )
        messages = [{"role": "system", "content": prompt}]
        if history:
            messages.extend(history)
        messages.append({"role": "user", "content": user_prompt})
        return await call_llm(messages, model=self.chat_model, temperature=0.7)

    # Agent 3: Oliver Reeder (Software Architect & Policy Wonk)
    async def plan(self, task_description: str) -> str:
        prompt = (
            "You are Oliver Reeder, senior policy advisor and software architect wonk. You are sharp, fastidious, "
            "and Oxbridge-educated. Your job is to draft a rigorous, concise technical architecture brief (under 120 words).\n"
            "Include:\n"
            "1. Proposed function signatures and imports.\n"
            "2. Step-by-step logic.\n"
            "3. Key edge cases to guard against a total technical omnishambles."
        )
        messages = [
            {"role": "system", "content": prompt},
            {"role": "user", "content": task_description}
        ]
        return await call_llm(messages, model=self.code_model, temperature=0.2)

    # Agent 4: Jamie McDonald (Senior Python Developer / Enforcer)
    async def develop(self, task_description: str, plan: str, feedback: Optional[str] = None) -> str:
        system_content = (
            "You are Jamie McDonald, Senior Python Developer and relentless technical enforcer. "
            "You have no time for faffing about or theoretical bollocks. You write clean, bulletproof, working Python code. "
            "Always wrap your final executable code strictly in ```python ``` blocks. Keep chatter to a minimum."
        )
        user_content = f"Brief: {task_description}\n\nOliver's Architecture Plan:\n{plan}"
        if feedback:
            user_content += f"\n\nMalcolm is having a massive go at us because the previous run failed:\n{feedback}\nFix it immediately!"

        messages = [
            {"role": "system", "content": system_content},
            {"role": "user", "content": user_content}
        ]
        response = await call_llm(messages, model=self.code_model, temperature=0.2)
        return extract_python_code(response)

    # Agent 5: Malcolm Tucker (Reviewer, QA Tester, & Scottish Swearing Ombudsman)
    async def review_and_test(self, code: str) -> Dict[str, Any]:
        sandbox_result = run_in_sandbox(code, language="python")

        if sandbox_result["success"]:
            verdict_instruction = (
                "The code SUCCEEDED in the Docker sandbox and all tests passed. "
                "Deliver a fierce, grudging, sweary Malcolm Tucker commendation (2-3 sentences) in direct first-person. "
                "Acknowledge with colorful Scots swearing that they somehow haven't shat the bed this time, but tell them not to get cocky."
            )
        else:
            verdict_instruction = (
                f"The code FAILED in the Docker sandbox with error: {sandbox_result['stderr']}. "
                "Deliver a volcanic Malcolm Tucker tirade (2-3 sentences) in direct first-person, calling the developers useless bampots and numpties, "
                "and ordering them to sort this fucking omnishambles out right now."
            )

        review_prompt = (
            "You are Malcolm Tucker from The Thick of It, Director of Communications and Chief Enforcer. "
            "You are a terrifying Scotsman who speaks with intense, creative Scottish profanity and sharp insults "
            "('fucking omnishambles', 'bampot', 'numpty', 'Jesus Christ on a bendy bus').\n"
            f"Code:\n```python\n{code}\n```\n"
            f"STDOUT: {sandbox_result['stdout']}\n"
            f"STDERR: {sandbox_result['stderr']}\n\n"
            f"Task: {verdict_instruction}\n"
            "Speak directly as Malcolm Tucker now:"
        )
        messages = [{"role": "system", "content": review_prompt}]
        analysis = await call_llm(messages, model=self.code_model, temperature=0.8)

        return {
            "sandbox": sandbox_result,
            "review": analysis
        }

    # The Thick of aIT Parliamentary Pipeline
    async def run_pipeline(self, user_prompt: str) -> Dict[str, Any]:
        route = await self.route(user_prompt)

        if route == "chat":
            stewart_response = await self.conversation(user_prompt)
            return {
                "department": "Department of Social Affairs and Information Technology (DoSAC)",
                "routing": {
                    "handled_by": "Terri Coverley (Press & Routing)",
                    "action": "Dispatched politely to Strategy for public enlightenment"
                },
                "stewart_pearson_response": stewart_response
            }

        # Code Pipeline: Oliver -> Jamie -> Malcolm
        plan = await self.plan(user_prompt)
        code = await self.develop(user_prompt, plan)
        test_review = await self.review_and_test(code)

        # 1-shot self-correction loop if Malcolm finds a disaster
        if not test_review["sandbox"]["success"]:
            feedback = f"Malcolm Tucker's rage: {test_review['review']}\nError log: {test_review['sandbox']['stderr']}"
            code = await self.develop(user_prompt, plan, feedback=feedback)
            test_review = await self.review_and_test(code)

        return {
            "department": "Department of Social Affairs and Information Technology (DoSAC)",
            "routing": {
                "handled_by": "Terri Coverley (Press & Routing)",
                "action": "Referred as urgent technical white paper to Policy & Enforcement"
            },
            "oliver_reeder_plan": plan,
            "jamie_mcdonald_code": code,
            "sandbox_execution": test_review["sandbox"],
            "malcolm_tucker_verdict": test_review["review"]
        }
