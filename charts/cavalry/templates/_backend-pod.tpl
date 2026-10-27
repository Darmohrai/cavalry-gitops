{{/*
Pod template of the backend. Shared by the Deployment (backend-deployment.yaml) and the
Argo Rollouts Rollout (backend-rollout.yaml), so both run exactly the same pods.
*/}}
{{- define "cavalry.backend.podTemplate" -}}
{{- $fullname := include "cavalry.fullname" . -}}
{{- $secretName := include "cavalry.secretName" . -}}
{{- $issuer := printf "http://%s-keycloak:%v/realms/%s" $fullname .Values.keycloak.port .Values.keycloak.realm -}}
metadata:
  labels:
    {{- include "cavalry.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  initContainers:
    - name: wait-for-postgres
      image: "{{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}"
      command:
        - sh
        - -c
        - until pg_isready -h {{ $fullname }}-postgres -p {{ .Values.postgres.port }}; do echo waiting for database; sleep 2; done
    - name: wait-for-keycloak
      image: "{{ .Values.initImage.repository }}:{{ .Values.initImage.tag }}"
      command:
        - sh
        - -c
        - until wget -qO- {{ $issuer }}/.well-known/openid-configuration > /dev/null 2>&1; do echo waiting for keycloak realm; sleep 2; done
  containers:
    - name: backend
      image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
      ports:
        - containerPort: {{ .Values.backend.containerPort }}
      {{- with .Values.backend.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      env:
        - name: SPRING_PROFILES_ACTIVE
          valueFrom:
            configMapKeyRef:
              name: {{ $fullname }}-config
              key: SPRING_PROFILES_ACTIVE
        - name: SPRING_RABBITMQ_HOST
          valueFrom:
            configMapKeyRef:
              name: {{ $fullname }}-config
              key: SPRING_RABBITMQ_HOST
        # DB name comes from the same Secret as the Postgres container uses
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: {{ $secretName }}
              key: POSTGRES_DB
        - name: SPRING_DATASOURCE_URL
          value: "jdbc:postgresql://{{ $fullname }}-postgres:{{ .Values.postgres.port }}/$(POSTGRES_DB)"
        - name: SPRING_DATASOURCE_USERNAME
          valueFrom:
            secretKeyRef:
              name: {{ $secretName }}
              key: POSTGRES_USER
        - name: SPRING_DATASOURCE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ $secretName }}
              key: POSTGRES_PASSWORD
        - name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI
          value: {{ $issuer | quote }}
        - name: SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_KEYCLOAK_ISSUER_URI
          value: {{ $issuer | quote }}
        {{- with .Values.backend.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      livenessProbe:
        tcpSocket:
          port: {{ .Values.backend.containerPort }}
        {{- toYaml .Values.backend.probes.liveness | nindent 8 }}
      readinessProbe:
        tcpSocket:
          port: {{ .Values.backend.containerPort }}
        {{- toYaml .Values.backend.probes.readiness | nindent 8 }}
{{- end }}
