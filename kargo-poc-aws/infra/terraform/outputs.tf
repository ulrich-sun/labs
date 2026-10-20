output "public_ip" {
  value = aws_instance.poc.public_ip
}

output "apps_domain" {
  description = "Domaine wildcard des applications (sslip.io résout vers l'IP publique)"
  value       = "apps.${aws_instance.poc.public_ip}.sslip.io"
}

output "urls" {
  description = "URL exposées par les HTTPRoutes (cf. gateway/)"
  value = {
    kargo              = "http://kargo.apps.${aws_instance.poc.public_ip}.sslip.io"
    argocd             = "http://argocd.apps.${aws_instance.poc.public_ip}.sslip.io"
    workflows          = "http://workflows.apps.${aws_instance.poc.public_ip}.sslip.io"
    excalidraw_dev     = "http://excalidraw-dev.apps.${aws_instance.poc.public_ip}.sslip.io"
    excalidraw_staging = "http://excalidraw-staging.apps.${aws_instance.poc.public_ip}.sslip.io"
    excalidraw_prod    = "http://excalidraw-prod.apps.${aws_instance.poc.public_ip}.sslip.io"
  }
}

output "ssh" {
  description = "Connexion simple"
  value       = "ssh ubuntu@${aws_instance.poc.public_ip}"
}
