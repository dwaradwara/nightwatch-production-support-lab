FROM nginx:1.29-alpine

ARG OPSFORGE_RELEASE_FAULT_MODE=none

COPY default.conf /etc/nginx/conf.d/default.conf

RUN if [ "$OPSFORGE_RELEASE_FAULT_MODE" = "ticket-create-500" ]; then \
      printf '%s\n' 'if ($request_method = POST) { return 500; }' > /etc/nginx/release-fault.inc; \
    else \
      : > /etc/nginx/release-fault.inc; \
    fi

EXPOSE 80
