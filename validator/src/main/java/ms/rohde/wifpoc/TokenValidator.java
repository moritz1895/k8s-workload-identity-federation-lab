package ms.rohde.wifpoc;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.BadJOSEException;
import com.nimbusds.jose.proc.JWSVerificationKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.ConfigurableJWTProcessor;
import com.nimbusds.jwt.proc.DefaultJWTClaimsVerifier;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;
import java.text.ParseException;
import java.util.Set;

/**
 * Validates Kubernetes projected ServiceAccount tokens entirely offline: it verifies the RS256/ES256
 * signature against the cluster JWKS and checks {@code iss}, {@code aud} and {@code exp}. No call to
 * the API server's TokenReview endpoint is made.
 */
public class TokenValidator {

    private static final Set<JWSAlgorithm> ACCEPTED_ALGS = Set.of(JWSAlgorithm.RS256, JWSAlgorithm.ES256);
    private static final Set<String> REQUIRED_CLAIMS = Set.of("sub", "iat", "exp");

    private final ConfigurableJWTProcessor<SecurityContext> processor;

    public TokenValidator(JWKSource<SecurityContext> jwkSource, String expectedIssuer, String expectedAudience) {
        DefaultJWTProcessor<SecurityContext> jwtProcessor = new DefaultJWTProcessor<>();
        jwtProcessor.setJWSKeySelector(new JWSVerificationKeySelector<>(ACCEPTED_ALGS, jwkSource));
        jwtProcessor.setJWTClaimsSetVerifier(new DefaultJWTClaimsVerifier<>(
                Set.of(expectedAudience),
                new JWTClaimsSet.Builder().issuer(expectedIssuer).build(),
                REQUIRED_CLAIMS,
                null));
        this.processor = jwtProcessor;
    }

    public ValidationResult validate(String bearerToken) {
        try {
            JWTClaimsSet claims = processor.process(bearerToken, null);
            return ValidationResult.ok(claims.toJSONObject());
        } catch (ParseException | BadJOSEException | JOSEException e) {
            return ValidationResult.rejected(e.getMessage());
        }
    }
}
