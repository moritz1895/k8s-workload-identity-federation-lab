package ms.rohde.wifpoc;

import java.nio.file.Path;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Trust configuration for the offline validator.
 *
 * @param issuer   the exact value the {@code iss} claim must carry; the validator runs OIDC
 *                 discovery against {@code issuer + "/.well-known/openid-configuration"} to find
 *                 the JWKS
 * @param audience the exact value that must appear in the token's {@code aud} claim
 * @param issuerCa PEM file with the CA (or self-signed cert) the issuer endpoint presents for TLS
 */
@ConfigurationProperties(prefix = "wif")
public record WifProperties(String issuer, String audience, Path issuerCa) {
}
