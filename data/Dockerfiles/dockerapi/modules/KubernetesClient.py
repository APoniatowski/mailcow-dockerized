import os
import re
import ssl
import json
import time
import shlex
import base64
import socket
import struct
import asyncio
import hashlib
import logging
import http.client
from decimal import Decimal
from datetime import datetime, timezone
from collections import namedtuple
from urllib.parse import quote, urlencode

# Kubernetes runtime for DockerApi, stdlib only. Mimics the subset of the docker /
# aiodocker client API that DockerApi.py and main.py use, so the exec table is
# shared and every caller keeps receiving docker-shaped JSON.

ExecResult = namedtuple('ExecResult', 'exit_code,output')

SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount'
COMPONENT_LABEL = 'app.kubernetes.io/component'
NULL_TIME = '0001-01-01T00:00:00Z'
CONNECT_TIMEOUT = 10
REQUEST_TIMEOUT = 30
EXEC_MAX_SECONDS = 300
RESTART_WAIT_SECONDS = 50
RESTART_POLL_SECONDS = 2
WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
WS_PROTOCOLS = 'v5.channel.k8s.io, v4.channel.k8s.io'

TOP_SCRIPT = (
  "ps -eo user,pid,ppid,etime,args 2>/dev/null || { echo 'USER PID PPID ELAPSED COMMAND'; "
  "for d in /proc/[0-9]*; do c=$(tr '\\000\\n' '  ' < \"$d/cmdline\" 2>/dev/null); "
  "[ -n \"$c\" ] && echo \"? ${d#/proc/} ? ? $c\"; done; true; }"
)

QUANTITY_SUFFIXES = {
  'n': Decimal('1e-9'), 'u': Decimal('1e-6'), 'm': Decimal('1e-3'), '': Decimal(1),
  'k': Decimal(10) ** 3, 'M': Decimal(10) ** 6, 'G': Decimal(10) ** 9, 'T': Decimal(10) ** 12, 'P': Decimal(10) ** 15, 'E': Decimal(10) ** 18,
  'Ki': Decimal(2) ** 10, 'Mi': Decimal(2) ** 20, 'Gi': Decimal(2) ** 30, 'Ti': Decimal(2) ** 40, 'Pi': Decimal(2) ** 50, 'Ei': Decimal(2) ** 60
}


class KubernetesError(Exception):
  def __init__(self, status, msg):
    super().__init__('kubernetes api %s: %s' % (status, msg))
    self.status = status


def _ts(value):
  if not value:
    return NULL_TIME
  try:
    dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
  except ValueError:
    return value
  if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
  return dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f000Z')


def _quantity(value):
  m = re.match(r'^([+-]?[0-9.]+(?:[eE][+-]?[0-9]+)?)([a-zA-Z]*)$', str(value or '0'))
  if not m or m.group(2) not in QUANTITY_SUFFIXES:
    return 0
  return int(Decimal(m.group(1)) * QUANTITY_SUFFIXES[m.group(2)])


def _user_cmd(cmd, user):
  # Kubernetes exec has no user option: switch user inside the container.
  # Only the user name ends up in the exec request, never the payload.
  if not user or user in ('root', '0'):
    return cmd
  u = shlex.quote(user)
  c = shlex.join(cmd)
  return ['/bin/sh', '-c',
    'if [ "$(id -u)" = "$(id -u ' + u + ' 2>/dev/null)" ]; then exec ' + c + '; '
    'elif command -v gosu >/dev/null 2>&1; then exec gosu ' + u + ' ' + c + '; '
    'else exec su -s /bin/sh -c ' + shlex.quote(c) + ' ' + u + '; fi']


def _exit_status(err):
  if not err:
    return 1, b'exec: no exit status received'
  try:
    status = json.loads(err)
  except ValueError:
    return 1, err
  if status.get('status') == 'Success':
    return 0, b''
  for cause in (status.get('details') or {}).get('causes') or []:
    if cause.get('reason') == 'ExitCode':
      try:
        return int(cause.get('message')), b''
      except (TypeError, ValueError):
        break
  return 126, (status.get('message') or 'exec failed').encode('utf-8')


def _mask(data, key):
  if not data:
    return data
  n = len(data)
  return (int.from_bytes(data, 'big') ^ int.from_bytes((key * (n // 4 + 1))[:n], 'big')).to_bytes(n, 'big')


class WebSocket:
  def __init__(self, sock, buf=b''):
    self.sock = sock
    self.buf = bytearray(buf)
    self.frag_op = None
    self.frag = b''

  def _read(self, n):
    while len(self.buf) < n:
      chunk = self.sock.recv(65536)
      if not chunk:
        raise EOFError('websocket closed')
      self.buf += chunk
    data = bytes(self.buf[:n])
    del self.buf[:n]
    return data

  def recv(self):
    while True:
      b1, b2 = self._read(2)
      op = b1 & 0x0f
      n = b2 & 0x7f
      if n == 126:
        n = struct.unpack('!H', self._read(2))[0]
      elif n == 127:
        n = struct.unpack('!Q', self._read(8))[0]
      key = self._read(4) if b2 & 0x80 else None
      data = self._read(n)
      if key:
        data = _mask(data, key)
      if op >= 0x8:
        return op, data
      if op:
        self.frag_op, self.frag = op, data
      else:
        self.frag += data
      if b1 & 0x80:
        op, data, self.frag_op, self.frag = self.frag_op, self.frag, None, b''
        return op, data

  def send(self, data, opcode=0x2):
    n = len(data)
    if n < 126:
      header = struct.pack('!BB', 0x80 | opcode, 0x80 | n)
    elif n < 65536:
      header = struct.pack('!BBH', 0x80 | opcode, 0x80 | 126, n)
    else:
      header = struct.pack('!BBQ', 0x80 | opcode, 0x80 | 127, n)
    key = os.urandom(4)
    self.sock.sendall(header + key + _mask(data, key))


class KubernetesApi:
  def __init__(self):
    self.host = os.environ.get('KUBERNETES_SERVICE_HOST', '')
    if not self.host:
      raise RuntimeError('kubernetes backend needs to run in a pod (KUBERNETES_SERVICE_HOST is not set)')
    self.port = int(os.environ.get('KUBERNETES_SERVICE_PORT', '443'))
    self.host_header = ('[%s]' % self.host if ':' in self.host else self.host) + ':%d' % self.port
    self.ssl = ssl.create_default_context(cafile=SA_DIR + '/ca.crt')

  def _token(self):
    # bound service account tokens rotate, read on every request
    with open(SA_DIR + '/token') as f:
      return f.read().strip()

  def request(self, method, path, body=None):
    headers = { 'Authorization': 'Bearer ' + self._token(), 'Accept': 'application/json' }
    data = None
    if body is not None:
      data = json.dumps(body).encode('utf-8')
      headers['Content-Type'] = 'application/json'
    conn = http.client.HTTPSConnection(self.host, self.port, context=self.ssl, timeout=REQUEST_TIMEOUT)
    try:
      conn.request(method, path, body=data, headers=headers)
      resp = conn.getresponse()
      payload = resp.read()
    finally:
      conn.close()
    if resp.status >= 400:
      try:
        msg = json.loads(payload).get('message', '')
      except ValueError:
        msg = payload[:200].decode('utf-8', 'replace')
      raise KubernetesError(resp.status, msg)
    return json.loads(payload) if payload else {}

  def exec(self, namespace, pod, container, command, stdin=None, eof=b'', timeout=EXEC_MAX_SECONDS):
    params = [('container', container), ('stdout', 'true'), ('stderr', 'true')]
    if stdin is not None:
      params.append(('stdin', 'true'))
    params += [('command', c) for c in command]
    path = '/api/v1/namespaces/%s/pods/%s/exec?%s' % (quote(namespace, safe=''), quote(pod, safe=''), urlencode(params))
    key = base64.b64encode(os.urandom(16)).decode('ascii')
    raw = socket.create_connection((self.host, self.port), timeout=CONNECT_TIMEOUT)
    try:
      sock = self.ssl.wrap_socket(raw, server_hostname=self.host)
    except Exception:
      raw.close()
      raise
    deadline = time.monotonic() + timeout
    out = bytearray()
    err = bytearray()
    try:
      sock.sendall(('GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
        'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: %s\r\n'
        'Authorization: Bearer %s\r\n\r\n' % (path, self.host_header, key, WS_PROTOCOLS, self._token())).encode('utf-8'))
      buf = b''
      while b'\r\n\r\n' not in buf:
        chunk = sock.recv(4096)
        if not chunk or len(buf) > 65536:
          raise KubernetesError(0, 'exec: invalid handshake response')
        buf += chunk
      head, buf = buf.split(b'\r\n\r\n', 1)
      lines = head.decode('latin-1').split('\r\n')
      status = lines[0].split(' ', 2)
      headers = dict((k.strip().lower(), v.strip()) for k, v in (l.split(':', 1) for l in lines[1:] if ':' in l))
      if len(status) < 2 or status[1] != '101':
        try:
          length = min(int(headers.get('content-length', 0)), 65536)
          while len(buf) < length:
            chunk = sock.recv(4096)
            if not chunk:
              break
            buf += chunk
        except (ValueError, OSError):
          pass
        try:
          msg = json.loads(buf).get('message', lines[0])
        except ValueError:
          msg = lines[0]
        raise KubernetesError(status[1] if len(status) > 1 else 0, 'exec: ' + msg)
      accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode('ascii')).digest()).decode('ascii')
      if headers.get('sec-websocket-accept') != accept:
        raise KubernetesError(101, 'exec: invalid Sec-WebSocket-Accept')
      protocol = headers.get('sec-websocket-protocol', '')
      if protocol not in ('v5.channel.k8s.io', 'v4.channel.k8s.io'):
        raise KubernetesError(101, 'exec: server did not negotiate v5.channel.k8s.io or v4.channel.k8s.io (got %r)' % protocol)
      ws = WebSocket(sock, buf)
      if stdin is not None:
        if protocol == 'v5.channel.k8s.io':
          ws.send(b'\x00' + stdin)
          ws.send(b'\xff\x00')
        else:
          ws.send(b'\x00' + stdin + eof)
      while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
          break
        sock.settimeout(remaining)
        try:
          op, data = ws.recv()
        except (EOFError, socket.timeout, OSError):
          break
        if op == 0x8:
          break
        if op == 0x9:
          ws.send(data, 0xA)
        elif op in (0x1, 0x2) and data:
          if data[0] in (1, 2):
            out += data[1:]
          elif data[0] == 3:
            err += data[1:]
      try:
        sock.settimeout(1)
        ws.send(b'\x03\xe8', 0x8)
      except OSError:
        pass
    finally:
      sock.close()
    return bytes(out), bytes(err)


class KubernetesContainer:
  def __init__(self, kube, pod):
    self.kube = kube
    self.pod = pod
    meta = pod['metadata']
    spec = pod.get('spec', {})
    status = pod.get('status', {})
    self.name = meta['name']
    self.uid = meta.get('uid', '')
    self.deleting = bool(meta.get('deletionTimestamp'))
    self.component = (meta.get('labels') or {}).get(COMPONENT_LABEL, '')
    self.service = self.component + '-mailcow'
    # stable across delete/recreate of a StatefulSet pod (callers cache the id)
    self.id = self._id = hashlib.sha256(('%s/%s' % (kube.namespace, self.name)).encode('utf-8')).hexdigest()
    containers = spec.get('containers') or []
    self.spec = next((c for c in containers if c.get('name') == self.service), containers[0])
    self.container = self.spec['name']
    self.status = next((s for s in (status.get('containerStatuses') or []) if s.get('name') == self.container), {})
    self.attrs = self._inspect()
    self.running = self.attrs['State']['Running'] and not self.deleting

  def _state(self):
    state = {
      'Status': 'created',
      'Running': False,
      'Paused': False,
      'Restarting': False,
      'OOMKilled': False,
      'Dead': False,
      'Pid': 0,
      'ExitCode': 0,
      'Error': '',
      'StartedAt': NULL_TIME,
      'FinishedAt': NULL_TIME
    }
    cs = self.status.get('state') or {}
    if 'running' in cs:
      state.update(Status='running', Running=True, StartedAt=_ts(cs['running'].get('startedAt')))
    else:
      term = cs.get('terminated') or (self.status.get('lastState') or {}).get('terminated')
      if term:
        state.update(Status='exited', ExitCode=term.get('exitCode') or 0, Error=term.get('message') or '',
          OOMKilled=(term.get('reason') == 'OOMKilled'), StartedAt=_ts(term.get('startedAt')), FinishedAt=_ts(term.get('finishedAt')))
      if 'waiting' in cs:
        state['Error'] = cs['waiting'].get('message') or cs['waiting'].get('reason') or ''
        if self.status.get('restartCount'):
          state.update(Status='restarting', Restarting=True)
    if self.deleting:
      state['Status'] = 'removing'
    return state

  def _inspect(self):
    meta = self.pod['metadata']
    status = self.pod.get('status', {})
    labels = dict(meta.get('labels') or {})
    labels['com.docker.compose.service'] = self.service
    labels['com.docker.compose.project'] = self.kube.project
    ips = [i.get('ip') for i in (status.get('podIPs') or []) if i.get('ip')] or ([status['podIP']] if status.get('podIP') else [])
    ipv4 = next((ip for ip in ips if ':' not in ip), ips[0] if ips else '')
    ipv6 = next((ip for ip in ips if ':' in ip), '')
    command = self.spec.get('command') or []
    return {
      'Id': self.id,
      'Created': _ts(meta.get('creationTimestamp')),
      'Path': command[0] if command else '',
      'Args': command[1:] + (self.spec.get('args') or []),
      'State': self._state(),
      'Image': self.status.get('imageID') or '',
      'Name': '/' + self.name,
      'RestartCount': self.status.get('restartCount') or 0,
      'HostConfig': {},
      'Mounts': [],
      'Config': {
        'Hostname': self.pod.get('spec', {}).get('hostname') or self.name,
        'Env': [],
        'Image': self.spec.get('image', ''),
        'Labels': labels
      },
      'NetworkSettings': {
        'IPAddress': ipv4,
        'GlobalIPv6Address': ipv6,
        'Networks': {
          self.kube.project + '_mailcow-network': {
            'Aliases': [self.service, self.component],
            'IPAddress': ipv4,
            'GlobalIPv6Address': ipv6
          }
        }
      }
    }

  def matches_name(self, name):
    return name in self.name or name in self.service

  def _exec(self, command, stdin=None, eof=b''):
    return self.kube.api.exec(self.kube.namespace, self.name, self.container, command, stdin=stdin, eof=eof)

  def _exec_script(self, shell, script, user):
    # shell scripts go through stdin: the exec request URI (audit log) only carries the shell.
    # The script must not end in a backslash, it would swallow the closing brace of the wrapper.
    script = '{\n' + script + '\n} </dev/null\n'
    return self._exec(_user_cmd([shell, '-s'], user), stdin=script.encode('utf-8'), eof=b'exit\n')

  def exec_run(self, cmd, user='', **kwargs):
    if isinstance(cmd, str):
      cmd = shlex.split(cmd)
    if len(cmd) == 3 and cmd[1] == '-c':
      out, err = self._exec_script(cmd[0], cmd[2], user)
    else:
      out, err = self._exec(_user_cmd(cmd, user))
    exit_code, msg = _exit_status(err)
    return ExecResult(exit_code, out + msg)

  def exec_stdin(self, cmd, user, timeout=2, shell_cmd="/bin/bash"):
    out, err = self._exec_script(shell_cmd, cmd, user)
    return out.decode('utf-8', 'replace')

  def restart(self, **kwargs):
    # the pod's controller recreates it; the uid precondition protects a recreated StatefulSet pod.
    # Like docker restart, block until the replacement runs (bounded).
    before = set(c.uid for c in self.kube.containers.candidates() if c.component == self.component)
    try:
      self.kube.api.request('DELETE', '/api/v1/namespaces/%s/pods/%s' % (quote(self.kube.namespace, safe=''), quote(self.name, safe='')),
        { 'apiVersion': 'v1', 'kind': 'DeleteOptions', 'preconditions': { 'uid': self.uid } })
    except KubernetesError as e:
      if e.status in (404, 409):
        # already gone or replaced
        return
      raise
    deadline = time.monotonic() + RESTART_WAIT_SECONDS
    while time.monotonic() < deadline:
      time.sleep(RESTART_POLL_SECONDS)
      try:
        if any(c.running and c.uid not in before for c in self.kube.containers.candidates() if c.component == self.component):
          return
      except Exception as e:
        self.kube.logger.warning("restart %s: polling for replacement pod failed: %s" % (self.name, e))
    self.kube.logger.warning("restart %s: no running replacement pod for component %s after %ss" % (self.name, self.component, RESTART_WAIT_SECONDS))

  def start(self, **kwargs):
    raise RuntimeError('start is not supported by the kubernetes backend, use restart')

  def stop(self, **kwargs):
    raise RuntimeError('stop is not supported by the kubernetes backend, use restart')

  def top(self, **kwargs):
    res = self.exec_run(['/bin/sh', '-c', TOP_SCRIPT])
    lines = res.output.decode('utf-8', 'replace').splitlines()
    if res.exit_code != 0 or not lines:
      raise RuntimeError('top failed: ' + res.output.decode('utf-8', 'replace'))
    titles = lines[0].split()
    return {
      'Titles': titles,
      'Processes': [line.split(None, len(titles) - 1) for line in lines[1:] if line.strip()]
    }

  def stats_once(self):
    mem = 0
    try:
      metrics = self.kube.api.request('GET', '/apis/metrics.k8s.io/v1beta1/namespaces/%s/pods/%s' % (quote(self.kube.namespace, safe=''), quote(self.name, safe='')))
      for c in metrics.get('containers', []):
        if c.get('name') == self.container:
          mem = _quantity((c.get('usage') or {}).get('memory'))
    except Exception:
      pass
    limit = _quantity(((self.spec.get('resources') or {}).get('limits') or {}).get('memory'))
    cpu = { 'cpu_usage': { 'total_usage': 0, 'usage_in_kernelmode': 0, 'usage_in_usermode': 0 }, 'system_cpu_usage': 0, 'online_cpus': 0 }
    return {
      'read': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f000Z'),
      'preread': NULL_TIME,
      'name': '/' + self.name,
      'id': self.id,
      'pids_stats': {},
      'blkio_stats': {
        'io_service_bytes_recursive': [],
        'io_serviced_recursive': None,
        'io_queue_recursive': None,
        'io_service_time_recursive': None,
        'io_wait_time_recursive': None,
        'io_merged_recursive': None,
        'io_time_recursive': None,
        'sectors_recursive': None
      },
      'num_procs': 0,
      'storage_stats': {},
      'cpu_stats': cpu,
      'precpu_stats': cpu,
      'memory_stats': { 'usage': mem, 'stats': {}, 'limit': limit },
      'networks': {}
    }

  def stats(self, decode=True, stream=True, **kwargs):
    yield self.stats_once()


class KubernetesContainers:
  def __init__(self, kube):
    self.kube = kube

  def candidates(self):
    # every mailcow pod, newest first; Job pods (CronJob runners, hooks) are not services
    path = '/api/v1/namespaces/%s/pods?%s' % (quote(self.kube.namespace, safe=''), urlencode({ 'labelSelector': self.kube.selector }))
    pods = self.kube.api.request('GET', path).get('items') or []
    pods.sort(key=lambda p: p['metadata'].get('creationTimestamp') or '', reverse=True)
    containers = []
    for pod in pods:
      meta = pod['metadata']
      if not (meta.get('labels') or {}).get(COMPONENT_LABEL) or not (pod.get('spec') or {}).get('containers'):
        continue
      if any(o.get('kind') == 'Job' for o in meta.get('ownerReferences') or []):
        continue
      containers.append(KubernetesContainer(self.kube, pod))
    return containers

  def list(self, all=False, filters=None, **kwargs):
    filters = filters or {}
    containers = []
    for container in self.candidates():
      if not all and not container.running:
        continue
      if 'id' in filters and not container.id.startswith(str(filters['id'])):
        continue
      if 'name' in filters and not container.matches_name(str(filters['name'])):
        continue
      containers.append(container)
    if all and 'id' not in filters:
      # callers key by service name: per component keep the running pods, else only the newest one,
      # so an evicted, failed or terminating pod never shadows the live one
      running = set(c.component for c in containers if c.running)
      seen = set()
      deduped = []
      for c in containers:
        if c.component in running:
          if c.running:
            deduped.append(c)
        elif c.component not in seen:
          deduped.append(c)
        seen.add(c.component)
      containers = deduped
    return containers


class KubernetesClient:
  def __init__(self, logger=None):
    self.api = KubernetesApi()
    self.namespace = os.environ.get('K8S_NAMESPACE') or self._sa_namespace()
    self.selector = os.environ.get('K8S_POD_SELECTOR') or 'app.kubernetes.io/name=mailcow'
    self.project = (os.environ.get('COMPOSE_PROJECT_NAME') or 'mailcowdockerized').lower()
    self.containers = KubernetesContainers(self)
    self.logger = logger or logging.getLogger('dockerapi')
    if logger:
      logger.info("kubernetes backend: namespace %s, pod selector %s, project %s" % (self.namespace, self.selector, self.project))
      if 'app.kubernetes.io/instance=' not in self.selector:
        logger.warning("K8S_POD_SELECTOR '%s' has no app.kubernetes.io/instance= term, pods of other mailcow releases in namespace %s will match" % (self.selector, self.namespace))
      if not os.environ.get('COMPOSE_PROJECT_NAME'):
        logger.warning("COMPOSE_PROJECT_NAME is not set, reporting project 'mailcowdockerized'; it must match the value php-fpm and the other containers use")

  def _sa_namespace(self):
    try:
      with open(SA_DIR + '/namespace') as f:
        return f.read().strip() or 'default'
    except OSError:
      return 'default'

  def close(self):
    pass


class AsyncKubernetesContainer:
  def __init__(self, container):
    self.container = container
    self._id = container.id

  async def show(self):
    return self.container.attrs

  async def stats(self, stream=False):
    return [await asyncio.to_thread(self.container.stats_once)]


class AsyncKubernetesContainers:
  def __init__(self, kube):
    self.kube = kube

  async def list(self, all=False, filters=None):
    containers = await asyncio.to_thread(self.kube.containers.list, all=all, filters=filters)
    return [AsyncKubernetesContainer(c) for c in containers]


class AsyncKubernetesClient:
  def __init__(self, kube):
    self.kube = kube
    self.containers = AsyncKubernetesContainers(kube)

  async def close(self):
    pass
