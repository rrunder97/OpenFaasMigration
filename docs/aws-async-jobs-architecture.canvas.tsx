import {
  Callout,
  Divider,
  Grid,
  H1,
  H2,
  H3,
  Pill,
  Row,
  Stack,
  Stat,
  Table,
  Text,
} from "cursor/canvas";

export default function AwsAsyncJobsArchitecture() {
  return (
    <Stack gap={20}>
      <H1>AWS Async Job Architecture</H1>
      <Text tone="secondary">
        OpenFaaS migration target: API Gateway submits jobs to SQS, ECS/Fargate workers process asynchronously,
        DynamoDB tracks job state, and CloudWatch monitors queue and DLQ health.
      </Text>

      <Grid columns={4} gap={12}>
        <Stat label="Public Route" value="POST /jobs" />
        <Stat label="Ingress Response" value="202 ACCEPTED" tone="success" />
        <Stat label="Primary Queue" value="SQS jobs" />
        <Stat label="Dead-Letter Queue" value="SQS jobs_dlq" tone="warning" />
      </Grid>

      <Divider />

      <H2>Architecture Flow (Request to Completion)</H2>
      <Table
        headers={["Step", "Service", "Action", "Data Contract", "Failure Behavior"]}
        rows={[
          [
            "1",
            "Client -> API Gateway",
            "Calls POST /jobs on REST API stage",
            "JSON object body",
            "Input validation/mapping at API edge only",
          ],
          [
            "2",
            "API Gateway -> SQS jobs",
            "AWS integration performs SendMessage",
            "MessageBody is URL-encoded raw request body",
            "If SQS send fails, request fails at submission time",
          ],
          [
            "3",
            "API Gateway -> Client",
            "Returns accepted semantics",
            "{ status: ACCEPTED }",
            "Processing is decoupled from HTTP lifetime",
          ],
          [
            "4",
            "ECS/Fargate sqs_worker.py",
            "Long-polls queue and receives one or more messages",
            "Body parsed as JSON object or payload wrapper",
            "Malformed payload can be marked FAILED and deleted",
          ],
          [
            "5",
            "Worker -> handler.process_event()",
            "Executes business logic",
            "dict payload plus request_id/job_id context",
            "Exceptions keep message for retry and eventual DLQ",
          ],
          [
            "6",
            "Worker -> DynamoDB job_status",
            "Updates lifecycle: PENDING -> RUNNING -> SUCCEEDED/FAILED",
            "Keyed by job_id",
            "Status updates are best effort and non-fatal to worker loop",
          ],
          [
            "7",
            "Worker -> SQS",
            "Deletes message only after successful processing path",
            "ReceiptHandle delete",
            "No delete on processing exception causes retry per redrive policy",
          ],
        ]}
      />

      <Divider />

      <Grid columns={2} gap={16}>
        <Stack gap={10}>
          <H3>Route and Integration Specifics</H3>
          <Row gap={8}>
            <Pill tone="info">API Type: REST API (Regional)</Pill>
            <Pill tone="info">Resource: /jobs</Pill>
            <Pill tone="info">Method: POST</Pill>
          </Row>
          <Text>
            API Gateway uses an AWS service integration to SQS (not Lambda proxy, not direct ECS invoke). The
            integration template sends:
          </Text>
          <Text>
            Action=SendMessage&MessageBody=$util.urlEncode($input.body)
          </Text>
          <Text tone="secondary">
            This keeps ingress fast and stable under long-running workloads because compute happens out-of-band.
          </Text>
        </Stack>

        <Stack gap={10}>
          <H3>Queue Processing Mechanics</H3>
          <Table
            headers={["Control", "Current Behavior"]}
            rows={[
              ["Long poll", "receive_message with WaitTimeSeconds (default 20)"],
              ["Visibility timeout", "Set on queue and receive call to cover long jobs"],
              ["Batch size", "MaxNumberOfMessages is configurable"],
              ["Poison message handling", "Malformed non-retryable payloads are deleted"],
              ["Retry behavior", "Processing exceptions leave message for retry"],
              ["DLQ handoff", "SQS redrive sends message to jobs_dlq after max receives"],
            ]}
          />
        </Stack>
      </Grid>

      <Divider />

      <H2>State Model and Observability</H2>
      <Grid columns={2} gap={16}>
        <Stack gap={10}>
          <H3>Job State Lifecycle (DynamoDB)</H3>
          <Row gap={8}>
            <Pill>PENDING</Pill>
            <Pill tone="warning">RUNNING</Pill>
            <Pill tone="success">SUCCEEDED</Pill>
            <Pill tone="deleted">FAILED</Pill>
          </Row>
          <Text>
            Records are keyed by <Text weight="bold">job_id</Text>. Timestamps and outcome details are written as work
            advances. Table uses on-demand billing and can expire records with TTL when configured.
          </Text>
          <Text tone="secondary">
            This state store decouples operator visibility from request-response timing and enables async status checks.
          </Text>
        </Stack>

        <Stack gap={10}>
          <H3>Monitoring and Scaling</H3>
          <Table
            headers={["Signal", "Metric", "Purpose"]}
            rows={[
              ["Queue backlog", "ApproximateNumberOfMessagesVisible", "Triggers ECS worker scale out/in"],
              ["Queue latency", "ApproximateAgeOfOldestMessage", "Detects processing lag/SLA drift"],
              ["DLQ presence", "DLQ visible messages > 0", "Flags failed jobs needing intervention"],
              ["Worker logs", "CloudWatch Logs /ecs/<name_prefix>", "Per-job execution diagnostics"],
            ]}
          />
        </Stack>
      </Grid>

      <Divider />

      <H2>DLQ Reprocessing Strategy</H2>
      <Callout tone="warning" title="Current posture">
        The deployed flow captures failures in DLQ. Reprocessing is an operator action unless an automated redrive
        workflow is added.
      </Callout>
      <Table
        headers={["Phase", "Recommended Team Runbook"]}
        rows={[
          [
            "Detect",
            "CloudWatch alarm fires when jobs_dlq has messages. On-call inspects failed payloads and root cause.",
          ],
          [
            "Triage",
            "Classify failures as transient (safe to retry) vs permanent (payload defect/business rule failure).",
          ],
          [
            "Repair",
            "Fix code/config/dependency issue first, or patch malformed payload where policy allows.",
          ],
          [
            "Redrive",
            "Use SQS redrive task or scripted move from DLQ back to jobs queue with rate controls.",
          ],
          [
            "Verify",
            "Track queue age/backlog/job_status transitions and close incident after successful drain.",
          ],
        ]}
      />

      <Divider />

      <H2>Presentation Notes for Team</H2>
      <Text>
        This is an async-first design. The HTTP route is a submission interface, not a compute interface. Throughput and
        resilience come from queue buffering, worker autoscaling, and explicit retry/DLQ controls.
      </Text>
      <Text tone="secondary">
        If the team wants synchronous behavior, that is a separate architecture where API routes invoke compute directly
        and return final results in the same request lifecycle.
      </Text>
    </Stack>
  );
}
