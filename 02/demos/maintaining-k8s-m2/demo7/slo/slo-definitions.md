# Service Level Objectives (SLO) Definitions

## Overview
This document defines the SLIs (Service Level Indicators) and SLOs (Service Level Objectives) for the GuestBook demo application.

## SLI Definitions

### 1. Availability SLI
**Definition**: Percentage of backend pods that are ready to serve traffic

**PromQL Query**:
```promql
# Pod readiness percentage
(kube_deployment_status_replicas_ready{deployment=~".*backend.*"} / kube_deployment_spec_replicas{deployment=~".*backend.*"}) * 100
```

**Measurement**:
- **Available**: Pods that pass readiness probe and can receive traffic
- **Unavailable**: Pods that are not ready (starting, crashing, or failing readiness checks)
- Example: 3 ready pods out of 4 total = 75% availability

**Why Pod-Based (Not HTTP Error Rate)?**
- When pods crash and restart, Kubernetes doesn't route traffic to unready pods
- HTTP requests go only to healthy pods, so HTTP error rate stays at 100%
- Pod readiness shows true service capacity and availability
- More meaningful for infrastructure/crash scenarios

### 2. Latency SLI (p95)
**Definition**: 95th percentile response time in milliseconds

**PromQL Query**:
```promql
# 95th percentile latency over 5 minutes
histogram_quantile(0.95, sum(rate(guestbook_request_duration_seconds_bucket[5m])) by (le)) * 1000
```

**Measurement**:
- Measured in milliseconds
- Tracks p95 (95% of requests faster than this threshold)

### 3. Error Rate SLI
**Definition**: Percentage of requests resulting in 5xx errors

**PromQL Query**:
```promql
# Error rate over 5 minutes
sum(rate(guestbook_requests_total{status=~"5.."}[5m])) / sum(rate(guestbook_requests_total[5m])) * 100
```

**Measurement**:
- Only counts 5xx errors (server-side failures)
- Excludes 4xx errors (client-side issues)

## SLO Definitions

### 1. Availability SLO
**Target**: 99.5% availability over a 30-day window

**Details**:
- **Objective**: 99.5% of requests must succeed (non-5xx)
- **Time Window**: 30 days (rolling)
- **Error Budget**: 0.5% = ~216 minutes of downtime per month
- **Alerting Threshold**: Alert when availability drops below 99.5%

**Error Budget Calculation**:
```
Total minutes in 30 days: 43,200 minutes
Error budget (0.5%): 216 minutes
Error budget (hours): 3.6 hours
```

### 2. Latency SLO
**Target**: 95% of requests must complete within 200ms

**Details**:
- **Objective**: p95 latency < 200ms
- **Time Window**: 5 minutes (immediate feedback)
- **Error Budget**: 5% of requests may exceed 200ms
- **Alerting Threshold**: Alert when p95 > 200ms for 5+ minutes

### 3. Error Rate SLO
**Target**: Error rate must stay below 0.5%

**Details**:
- **Objective**: < 0.5% of requests result in 5xx errors
- **Time Window**: 5 minutes (immediate feedback)
- **Error Budget**: Aligned with availability SLO
- **Alerting Threshold**: Alert when error rate > 0.5% for 5+ minutes

## Chaos Engineering Modes

### Latency Mode
- **Behavior**: Injects 200-500ms delays
- **Intensity**: Configurable (1-100%)
- **SLO Impact**: Violates Latency SLO (p95 > 200ms)

### Errors Mode
- **Behavior**: Returns HTTP 500 errors
- **Intensity**: Configurable (1-100%)
- **SLO Impact**: Violates Availability and Error Rate SLOs

### Crash Mode
- **Behavior**: Terminates pod (exit 1)
- **Intensity**: Configurable (1-100%)
- **SLO Impact**: Causes pod restarts, temporary availability impact

## Chaos Endpoints

### Enable Chaos
```bash
curl -X POST http://localhost:5000/api/chaos/enable \
  -H "Content-Type: application/json" \
  -d '{"mode": "latency", "intensity": 50}'
```

### Disable Chaos
```bash
curl -X POST http://localhost:5000/api/chaos/disable
```

### Check Status
```bash
curl http://localhost:5000/api/chaos/status
```

## Monitoring Metrics

### Key Prometheus Metrics

1. **guestbook_requests_total{method, endpoint, status}**
   - Counter: Total requests by method, endpoint, and status code

2. **guestbook_request_duration_seconds{method, endpoint}**
   - Histogram: Request duration distribution

3. **guestbook_slo_violations_total{type}**
   - Counter: SLO violations by type (availability, latency)

4. **guestbook_chaos_injections_total{type}**
   - Counter: Chaos injections by type (latency, error, crash)

## Dashboard Requirements

The SLO Dashboard should include:

1. **SLO Status Panel** (30 days)
   - Availability: Current vs. 99.5% target
   - Error budget remaining
   - Days until error budget reset

2. **Real-Time SLI Panels** (5 minutes)
   - Availability percentage
   - P95 latency (ms)
   - Error rate percentage

3. **Error Budget Tracking**
   - Error budget consumption over time
   - Time spent in violation state

4. **Chaos Engineering Status**
   - Current chaos mode
   - Chaos injections count
   - Impact on SLOs

5. **Error Budget Burn Rate**
   - Current burn rate vs. expected
   - Projected time to exhaust budget
   - Historical burn rate trends

## Course Demonstration Workflow

### Demo 1: Baseline Performance
1. Show SLO dashboard with all SLOs met
2. Explain each SLI and its target
3. Show error budget remaining

### Demo 2: Latency Violations
1. Enable latency chaos (50% intensity)
2. Observe p95 latency exceed 200ms
3. Show SLO violation in dashboard
4. Disable chaos and observe recovery

### Demo 3: Availability Violations
1. Enable error chaos (30% intensity)
2. Observe availability drop below 99.5%
3. Show error budget consumption
4. Demonstrate troubleshooting workflow

### Demo 4: Error Budget Exhaustion
1. Simulate prolonged outage
2. Show error budget depletion
3. Discuss implications and response strategies

## Troubleshooting Playbook

### When SLO is Violated

1. **Check Grafana SLO Dashboard**
   - Identify which SLO is violated
   - Determine severity and duration

2. **Check Application Logs** (Loki)
   ```logql
   {app="demo-app-backend"} |= "error" or "CHAOS"
   ```

3. **Check Pod Health**
   ```bash
   kubectl get pods -o wide
   kubectl describe pod <pod-name>
   ```

4. **Check Chaos Status**
   ```bash
   curl http://localhost:5000/api/chaos/status
   ```

5. **Disable Chaos if Active**
   ```bash
   curl -X POST http://localhost:5000/api/chaos/disable
   ```

6. **Monitor Recovery**
   - Watch SLO dashboard
   - Verify metrics return to baseline
   - Document incident and resolution

## References

- **Prometheus Metrics**: http://localhost:5000/metrics
- **Grafana**: http://localhost:3000
- **Application Logs**: Loki data source in Grafana
