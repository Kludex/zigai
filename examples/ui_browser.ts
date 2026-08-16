type UIChunk = {
  type: string;
  approvalId?: string;
  toolCallId?: string;
  delta?: string;
};

export async function streamAgent(endpoint: string): Promise<void> {
  const response = await fetch(endpoint, { method: "POST" });
  if (!response.ok || response.body === null) {
    throw new Error(`Agent request failed: ${response.status}`);
  }
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let pending = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      return;
    }
    pending += value;
    const records = pending.split("\n\n");
    pending = records.pop() ?? "";
    for (const record of records) {
      if (!record.startsWith("data: ") || record === "data: [DONE]") {
        continue;
      }
      const chunk = JSON.parse(record.slice(6)) as UIChunk;
      if (chunk.type === "text-delta") {
        document.body.append(chunk.delta ?? "");
      }
      if (chunk.type === "tool-approval-request") {
        await sendApproval(endpoint, chunk.approvalId ?? "", true);
      }
    }
  }
}

export async function sendApproval(
  endpoint: string,
  approvalId: string,
  approved: boolean,
): Promise<void> {
  await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      type: "tool-approval-response",
      approvalId,
      approved,
    }),
  });
}
