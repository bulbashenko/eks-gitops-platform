{{- define "service.name" -}}
{{- required "name is required" .Values.name -}}
{{- end -}}

{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/part-of: orders
{{- end -}}

{{- define "service.labels" -}}
{{ include "service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "service.image" -}}
{{- $repo := default (printf "egp/%s" (include "service.name" .)) .Values.image.repository -}}
{{- printf "%s/%s:%s" (required "image.registry is required" .Values.image.registry) $repo (required "image.tag is required: CI has not published an image yet" .Values.image.tag) -}}
{{- end -}}

{{- define "service.stableService" -}}
{{- if .Values.rollout.enabled }}{{ include "service.name" . }}-stable{{ else }}{{ include "service.name" . }}{{ end -}}
{{- end -}}

{{/* Pod template shared by Deployment and Rollout. */}}
{{- define "service.podTemplate" -}}
metadata:
  labels:
    {{- include "service.labels" . | nindent 4 }}
spec:
  serviceAccountName: {{ include "service.name" . }}
  automountServiceAccountToken: true
  terminationGracePeriodSeconds: 40
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  # Application pods run on Karpenter-managed capacity, never on the system node group.
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.egp.io/workload
                operator: In
                values: ["true"]
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          {{- include "service.selectorLabels" . | nindent 10 }}
  containers:
    - name: app
      image: {{ include "service.image" . }}
      ports:
        - name: http
          containerPort: {{ .Values.containerPort }}
      env:
        - name: AWS_REGION
          value: {{ required "platform.region is required" .Values.platform.region | quote }}
        {{- if .Values.aws.queue }}
        - name: SQS_QUEUE_URL
          value: {{ required "platform.ordersQueueUrl is required" .Values.platform.ordersQueueUrl | quote }}
        {{- end }}
        {{- if .Values.aws.bucket }}
        - name: S3_BUCKET
          value: {{ required "platform.receiptsBucket is required" .Values.platform.receiptsBucket | quote }}
        {{- end }}
        {{- range $k, $v := .Values.env }}
        - name: {{ $k }}
          value: {{ tpl (toString $v) $ | quote }}
        {{- end }}
      {{- if .Values.database.enabled }}
      envFrom:
        - secretRef:
            name: {{ include "service.name" . }}-db
      {{- end }}
      startupProbe:
        httpGet: { path: /healthz, port: http }
        periodSeconds: 2
        failureThreshold: 30
      livenessProbe:
        httpGet: { path: /healthz, port: http }
        periodSeconds: 10
      readinessProbe:
        httpGet: { path: /readyz, port: http }
        periodSeconds: 5
        failureThreshold: 2
      # Keep serving while the ALB deregisters the target, then shut down gracefully.
      lifecycle:
        preStop:
          sleep:
            seconds: 10
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: [ALL]
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
{{- end -}}
