"""Respond using the same buffered or SSE protocol the client requested."""
import json


PLAN_APPROACH = 'I will check the request and carry out the task.'


def handle_planning(handler, request):
    """Answer the tool-free preflight without consuming a scenario reply."""
    items = request.get('input', [])
    if not items or items[-1].get('role') != 'developer':
        return False
    if 'Before executing the latest user request' not in str(items[-1].get('content')):
        return False
    send_response(handler, request, {'status': 'completed', 'output': [
        {'type': 'message', 'role': 'assistant', 'content': [
            {'type': 'output_text', 'text': json.dumps({
                'title': 'Carry out the task', 'approach': PLAN_APPROACH})}]}]})
    return True


def send_response(handler, request, payload):
    if request.get('stream'):
        events = []
        if payload.get('status') in ('completed', 'incomplete'):
            for item in payload.get('output', []):
                if item.get('type') != 'message':
                    continue
                for part in item.get('content', []):
                    if part.get('type') == 'output_text':
                        text = part['text']
                        # Split text to exercise incremental rendering, including Unicode.
                        middle = len(text) // 2
                        for delta in (text[:middle], text[middle:]):
                            events.append({'type': 'response.output_text.delta', 'delta': delta})
        status = payload.get('status', 'completed')
        events.append({'type': f'response.{status}', 'response': payload})
        data = ''.join(f'data: {json.dumps(event)}\n\n' for event in events).encode()
        content_type = 'text/event-stream'
    else:
        data = json.dumps(payload).encode()
        content_type = 'application/json'
    handler.send_response(200)
    handler.send_header('Content-Type', content_type)
    handler.send_header('Content-Length', str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)
