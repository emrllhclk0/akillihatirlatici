import json
import os

transcript_path = r"C:\Users\EMRULLAH ÇELİK\.gemini\antigravity\brain\b5de6387-1519-49b2-8a9d-daadf6a7a8dc\.system_generated\logs\transcript.jsonl"
last_content = ""

with open(transcript_path, 'r', encoding='utf-8') as f:
    for line in f:
        try:
            data = json.loads(line)
            if data.get('source') == 'MODEL' and data.get('type') == 'PLANNER_RESPONSE':
                for tc in data.get('tool_calls', []):
                    if tc.get('name') == 'default_api:view_file':
                        args = tc.get('args', {})
                        if args.get('AbsolutePath') and 'main.dart' in args.get('AbsolutePath'):
                            # Wait, view_file doesn't show the full content in the MODEL's tool call. It shows in the tool response!
                            pass
            elif data.get('source') == 'SYSTEM' and data.get('type') == 'TOOL_RESPONSE':
                # Actually, TOOL_RESPONSE has the output!
                output = data.get('content', '')
                if 'The following code has been modified' in output and 'main.dart' in output:
                    # Let's save the largest one we find that is full! Wait, no full view_file was done.
                    pass
        except Exception as e:
            pass

# Since we don't have a full view_file, we must parse the python script to reconstruct the file.
# But wait! I only added 5 features today!
# I can just rewrite the 5 features. It's much faster.
