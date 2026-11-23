// M0 benchmark load script for k6 (HTTP/1.1 only).
//
// Environment variables:
//   TARGET      base URL of the server, e.g. http://messhost:8080 (required)
//   SCENARIO    plaintext | json | bytes64k | bytes1m | echo16k | echo1m | rate
//   VUS         virtual users (constant-vus), or preallocated VUs for "rate"
//   DURATION    measurement duration, default 30s
//   KEEPALIVE   1 (default) or 0; 0 sends "Connection: close" and disables reuse
//   RATE        requests per second for SCENARIO=rate, default 5000
//   CANDIDATE   candidate name, written into the summary
//   RUN         run number (1..3) or "warmup", written into the summary
//   OUT         path of the JSON summary file (handleSummary), default summary.json
//
// HTTP/1.1 is enforced in two ways: start k6 with GODEBUG=http2client=0 (this
// matters for https targets), and every response is checked for
// res.proto === 'HTTP/1.1'; anything else counts as an error.

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Counter } from 'k6/metrics';

const TARGET = (__ENV.TARGET || '').replace(/\/+$/, '');
const SCENARIO = __ENV.SCENARIO || 'plaintext';
const VUS = parseInt(__ENV.VUS || '16', 10);
const DURATION = __ENV.DURATION || '30s';
const KEEPALIVE = (__ENV.KEEPALIVE || '1') !== '0';
const RATE = parseInt(__ENV.RATE || '5000', 10);
const CANDIDATE = __ENV.CANDIDATE || 'unknown';
const RUN = __ENV.RUN || '1';
const OUT = __ENV.OUT || 'summary.json';

if (!TARGET) {
  throw new Error('TARGET is required, e.g. --env TARGET=http://messhost:8080');
}

const benchErrors = new Rate('bench_errors');
const protoErrors = new Counter('bench_proto_errors');

function makeBody(size) {
  // Deterministic payload, built once per VU.
  const chunk = 'abcdefghijklmnopqrstuvwxyz0123456789'.repeat(32); // 1152 bytes
  let s = '';
  while (s.length < size) {
    s += chunk;
  }
  return s.substring(0, size);
}

const SCENARIOS = {
  plaintext: { method: 'GET', path: '/plaintext', expectLength: 13 },
  json: { method: 'GET', path: '/json', expectLength: 27 },
  bytes64k: { method: 'GET', path: '/bytes/64k', expectLength: 65536 },
  bytes1m: { method: 'GET', path: '/bytes/1m', expectLength: 1048576 },
  echo16k: { method: 'POST', path: '/echo', bodySize: 16384 },
  echo1m: { method: 'POST', path: '/echo', bodySize: 1048576 },
  rate: { method: 'GET', path: '/plaintext', expectLength: 13 },
};

const spec = SCENARIOS[SCENARIO];
if (!spec) {
  throw new Error('Unknown SCENARIO ' + SCENARIO);
}

function buildScenario() {
  if (SCENARIO === 'rate') {
    return {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: VUS,
      maxVUs: Math.max(VUS, 2048),
    };
  }
  return { executor: 'constant-vus', vus: VUS, duration: DURATION };
}

export const options = {
  scenarios: { bench: buildScenario() },
  noConnectionReuse: !KEEPALIVE,
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'max'],
  // No thresholds: the runner evaluates the summary; a run never aborts early.
  tags: { candidate: CANDIDATE, scenario: SCENARIO },
};

const params = {
  headers: KEEPALIVE ? {} : { Connection: 'close' },
  responseType: spec.expectLength && spec.expectLength > 65536 ? 'binary' : 'text',
  timeout: '30s',
};
if (spec.method === 'POST') {
  params.headers['Content-Type'] = 'application/octet-stream';
}

let body = null;

export default function () {
  let res;
  if (spec.method === 'POST') {
    if (body === null) {
      body = makeBody(spec.bodySize);
    }
    res = http.post(TARGET + spec.path, body, params);
  } else {
    res = http.get(TARGET + spec.path, params);
  }
  const protoOk = res.proto === 'HTTP/1.1';
  if (!protoOk) {
    protoErrors.add(1);
  }
  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'proto is HTTP/1.1': () => protoOk,
    'body ok': (r) => {
      if (spec.method === 'POST') {
        return String(r.body).trim() === String(spec.bodySize);
      }
      const len = r.body ? (typeof r.body === 'string' ? r.body.length : r.body.byteLength) : 0;
      return len === spec.expectLength;
    },
  });
  benchErrors.add(!ok);
}

export function handleSummary(data) {
  data.bench = {
    candidate: CANDIDATE,
    scenario: SCENARIO,
    vus: VUS,
    keepalive: KEEPALIVE ? 1 : 0,
    run: RUN,
    duration: DURATION,
    rate: SCENARIO === 'rate' ? RATE : null,
    target: TARGET,
    k6_version: typeof __K6_VERSION !== 'undefined' ? __K6_VERSION : null,
    godebug: __ENV.GODEBUG || '',
  };
  const out = {};
  out[OUT] = JSON.stringify(data, null, 2);
  out.stdout = CANDIDATE + ' ' + SCENARIO + ' vus=' + VUS + ' ka=' + (KEEPALIVE ? 1 : 0) +
    ' run=' + RUN + ' reqs=' + data.metrics.http_reqs.values.count +
    ' rps=' + data.metrics.http_reqs.values.rate.toFixed(1) +
    ' p99=' + data.metrics.http_req_duration.values['p(99)'].toFixed(2) + 'ms' +
    ' err=' + (data.metrics.bench_errors ? (data.metrics.bench_errors.values.rate * 100).toFixed(3) : 'n/a') + '%\n';
  return out;
}
