import Authentication
import JWT
import Sugar
import Vapor

public protocol ResetControllerType {
    func renderResetPasswordRequestForm(_ req: Request) throws -> Future<Response>
    func resetPasswordRequest(_ req: Request) throws -> Future<Response>
    func renderResetPasswordForm(_ req: Request) throws -> Future<Response>
    func resetPassword(_ req: Request) throws -> Future<Response>
}

open class ResetController
    <U: JWTAuthenticatable & PasswordResettable>: ResetControllerType
{
    public init() {}

    open func renderResetPasswordRequestForm(_ req: Request) throws -> Future<Response> {
        let config: ResetConfig<U> = try req.make()
        return try config.responses.resetPasswordRequestForm(req)
    }

    open func resetPasswordRequest(_ req: Request) throws -> Future<Response> {
        let config: ResetConfig<U> = try req.make()
        let logger = try req.make(Logger.self)
        logger.debug("Reset password request")
        return U.RequestReset.create(on: req)
            .flatMap(to: U?.self) { 
                logger.debug("Getting user")
                return try U.find(by: $0, on: req) 
            }
            .flatTry { user in
                logger.debug("Getting user query returned")
                guard let user = user else {
                    // ignore case where user could not be found to prevent malicious attackers from
                    // finding out which accounts are available on the system
                    return .done(on: req)
                }
                return try config.reset(
                    user,
                    context: U.Context.requestResetPassword(),
                    on: req
                )
            }
            .flatMap(to: Response.self) { _ in
                logger.debug("About to return the reset password data")
                return try config.responses.resetPasswordUserNotified(req)
            }
    }

    open func renderResetPasswordForm(_ req: Request) throws -> Future<Response> {
        let config: ResetConfig<U> = try req.make()
        let payload = try config.extractVerifiedPayload(from: req.parameters.next())

        return try U
            .authenticate(using: payload, on: req)
            .unwrap(or: ResetError.userNotFound)
            .flatMap(to: Response.self) { user in
                guard user.passwordChangeCount == payload.passwordChangeCount else {
                    throw ResetError.tokenAlreadyUsed
                }
                return try config.responses.resetPasswordForm(req, user)
            }
    }

    open func resetPassword(_ req: Request) throws -> Future<Response> {
        let config: ResetConfig<U> = try req.make()
        let payload = try config.extractVerifiedPayload(from: req.parameters.next())

        return try U
            .authenticate(using: payload, on: req)
            .unwrap(or: ResetError.userNotFound)
            .try { user in
                guard user.passwordChangeCount == payload.passwordChangeCount else {
                    throw ResetError.tokenAlreadyUsed
                }
            }
            .and(U.ResetPassword.create(on: req))
            .flatMap(to: U.self) { user, resetPassword in
                var user = user
                let password = resetPassword[keyPath: U.ResetPassword.readablePasswordKey]
                user[keyPath: U.passwordKey] = try U.hashPassword(password)
                user.passwordChangeCount += 1
                return user.save(on: req)
            }
            .flatMap(to: Response.self) { user in
                try config.responses.resetPasswordSuccess(req, user)
            }
    }
}

public extension ResetConfig {
    func extractVerifiedPayload(from token: String) throws -> U.JWTPayload {
        let payload = try JWT<U.JWTPayload>(from: token, verifiedUsing: signer).payload

        try payload.verify(using: signer)

        return payload
    }
}
