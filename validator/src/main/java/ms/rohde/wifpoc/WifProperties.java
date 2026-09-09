package ms.rohde.wifpoc;

import java.nio.file.Path;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Trust configuration for the offline validator.
 *
 * @param issuer    the exact value the {@code iss} claim must carry; also the base URL the JWKS
 *                  is loaded from ({@code issuer + "/openid/v1/jwks"})
 * @param audience  the exact value that must appear in the token's {@code aud} claim
 * @param clusterCa PEM file with the CA that signed the cluster API server's serving certificate
 */
@ConfigurationProperties(prefix = "wif")
public record WifProperties(String issuer, String audience, Path clusterCa) {
}
