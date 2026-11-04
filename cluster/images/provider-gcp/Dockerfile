FROM alpine:3.24.4

# The build context always contains this file. Local build tooling copies the
# configured corporate CA bundle into it; an empty file preserves normal public
# builds. Install the extra roots before apk contacts Alpine mirrors.
COPY corporate-ca.pem /usr/local/share/ca-certificates/corporate-ca.crt
RUN if [ -s /usr/local/share/ca-certificates/corporate-ca.crt ]; then \
      cat /usr/local/share/ca-certificates/corporate-ca.crt >> /etc/ssl/cert.pem; \
    fi && \
    apk --no-cache add ca-certificates bash && \
    update-ca-certificates

ARG TARGETOS
ARG TARGETARCH
ARG CROSSPLANE_PROVIDER_VERSION

ENV USER_ID=65532
# set user agent
ENV GOOGLE_TERRAFORM_USERAGENT_EXTENSION="upbound-provider-gcp/${CROSSPLANE_PROVIDER_VERSION}"

USER ${USER_ID}
EXPOSE 8080

ENTRYPOINT ["provider"]

