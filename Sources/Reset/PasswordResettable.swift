import Authentication
import Fluent
import JWT
import Submissions
import Sugar
import Vapor

public protocol HasPasswordChangeCount {
    var passwordChangeCount: Int { get }
}

public protocol HasRequestResetPasswordContext {
    static func requestResetPassword() -> Self
}

public enum ResetPasswordContext: HasRequestResetPasswordContext {
    case userRequestedToResetPassword

    public static func requestResetPassword() -> ResetPasswordContext {
        return .userRequestedToResetPassword
    }
}

public protocol PasswordResettable:
    HasPassword,
    HasPasswordChangeCount,
    JWTAuthenticatable,
    Model
where
    Self.JWTPayload: HasPasswordChangeCount
{
    associatedtype Context: HasRequestResetPasswordContext
    associatedtype RequestReset: Creatable
    associatedtype ResetPassword: Creatable, HasReadablePassword

    static func find(
        by requestLink: RequestReset,
        on connection: DatabaseConnectable
    ) throws -> Future<Self?>

    func sendPasswordReset(
        url: String,
        token: String,
        expirationPeriod: TimeInterval,
        context: Context,
        on req: Request
    ) throws -> Future<Void>

    /// By incrementing this value on each password change and including it in the JWT payload,
    /// this value ensures that a password reset token can only be used once.
    var passwordChangeCount: Int { get set }

    static func expirationPeriod(for context: Context) -> TimeInterval
}

public extension PasswordResettable {
    static func expirationPeriod(for context: Context) -> TimeInterval {
        return 1.hoursInSecs
    }
}

extension PasswordResettable where
    Self: PasswordAuthenticatable,
    Self.RequestReset: HasReadableUsername
{
    public static func find(
        by payload: RequestReset,
        on connection: DatabaseConnectable
    ) -> Future<Self?> {
        let username = payload[keyPath: RequestReset.readableUsernameKey]
        print("Looking for user \(username)")
        fflush(stdout)
        return query(on: connection).filter(Self.usernameKey == username).first()
    }
}

extension PasswordResettable where
    Self.JWTPayload: ModelPayloadType,
    Self == Self.JWTPayload.PayloadModel
{
    public func makePayload(
        expirationTime: Date,
        on container: Container
    ) -> Future<JWTPayload> {
        return Future.map(on: container) {
            try Self.JWTPayload(expirationTime: expirationTime, model: self)
        }
    }
}

public protocol ModelPayloadType: ExpireableSubjectPayload, HasPasswordChangeCount {
    associatedtype PayloadModel: Model
    init(expirationTime: Date, model: PayloadModel) throws
}

public struct ModelPayload<U: Model>:
    ModelPayloadType
where
    U: HasPasswordChangeCount,
    U.ID: LosslessStringConvertible
{
    public typealias PayloadModel = U

    public let exp: ExpirationClaim
    public let pcc: PasswordChangeCountClaim
    public let sub: SubjectClaim

    public init(
        expirationTime: Date,
        model: U
    ) throws {
        self.exp = ExpirationClaim(value: expirationTime)
        self.pcc = PasswordChangeCountClaim(value: model.passwordChangeCount)
        self.sub = try SubjectClaim(value: model.requireID().description)
    }

    public var passwordChangeCount: Int {
        return pcc.value
    }

    public func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
    }
}
