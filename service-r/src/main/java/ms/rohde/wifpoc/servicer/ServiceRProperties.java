package ms.rohde.wifpoc.servicer;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Trust settings of service R.
 *
 * @param issuer   issuer URL of the domain authorization server realm; the only accepted {@code iss}
 * @param audience value that must appear in the access token's {@code aud} claim
 */
@ConfigurationProperties("service-r")
public record ServiceRProperties(String issuer, String audience) {
}
