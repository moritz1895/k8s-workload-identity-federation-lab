package ms.rohde.wifpoc;

import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * Outcome of validating a bearer token.
 *
 * @param valid  whether signature, issuer, audience and expiry all checked out
 * @param claims the token claims as JSON-friendly values when {@code valid}, otherwise {@code null}
 * @param reason a short rejection reason when not {@code valid}, otherwise {@code null}
 */
public record ValidationResult(boolean valid,
                               @Nullable Map<String, Object> claims,
                               @Nullable String reason) {

    public static ValidationResult ok(Map<String, Object> claims) {
        return new ValidationResult(true, claims, null);
    }

    public static ValidationResult rejected(String reason) {
        return new ValidationResult(false, null, reason);
    }
}
