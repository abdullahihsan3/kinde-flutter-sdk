import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    as secure_store;
import 'package:hive/hive.dart';
import 'package:jose/jose.dart';
import 'package:kinde_flutter_sdk/kinde_flutter_sdk.dart';
import 'package:kinde_flutter_sdk/src/handle_network_error_mixin.dart';
import 'package:kinde_flutter_sdk/src/keys/keys_api.dart';
import 'package:kinde_flutter_sdk/src/kinde_error.dart';
import 'package:kinde_flutter_sdk/src/store/store.dart';
import 'package:kinde_flutter_sdk/src/token/auth_state.dart';
import 'package:kinde_flutter_sdk/src/token/refresh_token_interceptor.dart';
import 'package:kinde_flutter_sdk/src/token/token_api.dart';
import 'package:kinde_flutter_sdk/src/token/token_utils.dart';
import 'package:oauth_webauth/oauth_webauth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:url_launcher/url_launcher.dart';

class KindeFlutterSDK with TokenUtils, HandleNetworkMixin {
  static const _orgCodeParamName = 'org_code';
  static const _orgNameParamName = 'org_name';
  static const _audienceParamName = 'audience';
  static const _createOrgParamName = 'is_create_org';
  static const _redirectParamName = 'redirect';
  static const _postLogoutRedirectParamName = 'post_logout_redirect_uri';
  static const _registrationPageParamName = 'start_page';
  static const _registrationPageParamValue = 'registration';
  static const _authPath = '/oauth2/auth';
  static const _tokenPath = '/oauth2/token';
  static const _logoutPath = '/logout';
  static const _defaultScopes = ['openid', 'profile', 'email', 'offline'];
  static const _bearerAuth = 'kindeBearerAuth';
  static const _clientIdParamName = 'client_id';

  // Singleton
  static KindeFlutterSDK? _instance;

  @override
  AuthState? get authState => _store.authState;

  static AuthConfig? _config;
  late KindeApi _kindeApi;
  late KeysApi _keysApi;
  late TokenApi _tokenApi;
  late AuthorizationServiceConfiguration _serviceConfiguration;

  static KindeFlutterSDK get instance {
    _instance ??= KindeFlutterSDK._internal();
    return _instance ?? KindeFlutterSDK._internal();
  }

  KindeFlutterSDK._internal() {
    if (_config == null) {
      throw KindeError('KindeFlutterSDK have not been configured');
    }

    var domainUrl = "";
    if (_config!.authDomain.startsWith('https')) {
      domainUrl = _config!.authDomain;
    } else if (_config!.authDomain.startsWith('http')) {
      domainUrl = _config!.authDomain.replaceFirst('http', "https");
    } else {
      domainUrl = 'https://${_config!.authDomain}';
    }

    _serviceConfiguration = AuthorizationServiceConfiguration(
        authorizationEndpoint: '$domainUrl$_authPath',
        tokenEndpoint: '$domainUrl$_tokenPath',
        endSessionEndpoint: '$domainUrl$_logoutPath');

    Dio dio = Dio(BaseOptions(
      baseUrl: domainUrl,
    ));

    _kindeApi = KindeApi(dio: dio, interceptors: [
      BearerAuthInterceptor(),
      RefreshTokenInterceptor(
        dio: dio,
        refreshToken: getToken,
      ),
    ]);
    _keysApi = KeysApi(_kindeApi.dio);
    _tokenApi = TokenApi(_kindeApi.dio);

    if (_store.keys == null) {
      _keysApi.getKeys().then((value) {
        _store.keys = value;
      });
    }

    var token = authState?.accessToken;
    if (token != null) {
      _kindeApi.setBearerAuth(_bearerAuth, token);
    }
  }

  Store get _store => Store.instance;

  static Future<void> initializeSDK({required String authDomain,
    required String authClientId,
    required String loginRedirectUri,
    required String logoutRedirectUri,
    List<String> scopes = _defaultScopes,
    String? audience}) async {
    _config = AuthConfig(
        authDomain: authDomain,
        authClientId: authClientId,
        loginRedirectUri: loginRedirectUri,
        logoutRedirectUri: logoutRedirectUri,
        scopes: scopes,
        audience: audience);

    secure_store.FlutterSecureStorage secureStorage =
    const secure_store.FlutterSecureStorage(
        aOptions: secure_store.AndroidOptions());

    Future<List<int>> getSecureKey(
        secure_store.FlutterSecureStorage secureStorage) async {
      var containsEncryptionKey =
      await secureStorage.containsKey(key: 'encryptionKey');
      if (!containsEncryptionKey) {
        var key = Hive.generateSecureKey();
        await secureStorage.write(
            key: 'encryptionKey', value: base64UrlEncode(key));
        return key;
      } else {
        final base64 = await secureStorage.read(key: 'encryptionKey');
        return base64Url.decode(base64!);
      }
    }

    final secureKey = await getSecureKey(secureStorage);

    var path = "/assets/db";
    if (!kIsWeb) {
      var appDocDir = await getTemporaryDirectory();
      path = appDocDir.path;
    }


    await Store.init(HiveAesCipher(secureKey), path);
  }

  Future<void> logout() async {
    if (Platform.isIOS) {
      final browser = ChromeSafariBrowser();
      await browser.open(url: _buildEndSessionUrl()).then((value) async {
        await browser.close();
      });
    } else {
      await launchUrl(Uri.parse(_buildEndSessionUrl().toString()));
    }
    _kindeApi.setBearerAuth(_bearerAuth, '');
    await Store.instance.clear();
  }

  Future<String?> login(BuildContext context,{AuthFlowType? type, String? orgCode}) async {
    return _redirectToKinde(context,type: type, orgCode: orgCode);
  }

  Future<String?> _redirectToKinde(BuildContext context,{AuthFlowType? type,
    String? orgCode,
    Map<String, String> additionalParams = const {}}) async {
    final params = HashMap<String, String>.from(additionalParams);
    if (orgCode != null) {
      params.putIfAbsent(_orgCodeParamName, () => orgCode);
    }
    if (_config?.audience != null) {
      params.putIfAbsent(_audienceParamName, () => _config!.audience!);
    }
    if(kIsWeb){
      _webLogin(params,context);
    }
    else {
      if (type == AuthFlowType.pkce) {
        return _pkceLogin(params);
      } else {
        return _normalLogin(params);
      }
    }
  }

  Future<void> register(BuildContext context,{AuthFlowType? type, String? orgCode}) async {
    await _redirectToKinde(context, type: type, orgCode: orgCode, additionalParams: {
      _registrationPageParamName: _registrationPageParamValue
    });
  }

  Future<UserProfileV2?> getUserProfileV2() async {
    return _kindeApi.getOAuthApi().getUserProfileV2().then((value) {
      return value.data;
    }).catchError((error) {
      throw handleError(error);
    });
  }

  Future<UserProfile?> getUser() async {
    return _kindeApi.getOAuthApi().getUser().then((value) {
      return value.data;
    }).catchError((error) {
      throw handleError(error);
    });
  }

  Future<void> createOrg(BuildContext context,{required String orgName, AuthFlowType? type}) async {
    await _redirectToKinde(context,type: type, orgCode: null, additionalParams: {
      _registrationPageParamName: _registrationPageParamValue,
      _createOrgParamName: "true",
      _orgNameParamName: orgName
    });
  }

  Future<String?> getToken() async {
    if (await isAuthenticate()) {
      return _store.authState?.accessToken;
    }
    final version = await _getVersion();
    final versionParam = 'Flutter/$version';
    try {
      if (authState?.refreshToken == null) {
        throw KindeError("Session expired or invalid");
      }
      final data = await _tokenApi.retrieveToken(
          versionParam,
          _store.authState!.createRequestTokenParam()
            ..putIfAbsent(_clientIdParamName, () => _config!.authClientId));
      _store.authState = AuthState.fromJson(data as Map<String, dynamic>);
      _kindeApi.setBearerAuth(_bearerAuth, _store.authState?.accessToken ?? '');
      return _store.authState?.accessToken;
    } on KindeError catch (_) {
      rethrow;
    } on Exception catch (ex) {
      throw handleError(ex);
    }
  }

  Future<bool> isAuthenticate() async =>
      authState != null && !authState!.isExpired() && await _checkToken();

  Future<String?> _normalLogin(Map<String, String> additionalParams) async {
    const appAuth = FlutterAppAuth();
    return await appAuth
        .authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        _config!.authClientId,
        _config!.loginRedirectUri,
        serviceConfiguration: _serviceConfiguration,
        scopes: _config!.scopes,
        promptValues: ['login'],
        additionalParameters: additionalParams,
      ),
    )
        .then((value) {
      if (additionalParams.containsKey(_orgNameParamName)) {
        return additionalParams[_orgNameParamName];
      }
      _saveState(value);
      return value?.accessToken;
    }).catchError((ex) {
      return null;
    });
  }
  String generateRandomState({int length = 8}) {
    final random = Random();
    String generateRandomChar() {
      int codePoint = random.nextInt(26) + 97; // Random lowercase letter (a-z)
      return String.fromCharCode(codePoint);
    }
    return List.generate(length, (index) => generateRandomChar()).join();
  }

  Future<String?> _pkceLogin(Map<String, String> additionalParams) async {
      const appAuth = FlutterAppAuth();
      try {
        final result = await appAuth.authorize(
          AuthorizationRequest(
            _config!.authClientId,
            _config!.loginRedirectUri,
            serviceConfiguration: _serviceConfiguration,
            scopes: _config!.scopes,
            promptValues: ['login'],
            additionalParameters: additionalParams,
          ),
        );
        final token = await appAuth.token(
          TokenRequest(
            _config!.authClientId,
            _config!.loginRedirectUri,
            codeVerifier: result!.codeVerifier,
            authorizationCode: result.authorizationCode,
            serviceConfiguration: _serviceConfiguration,
            nonce: result.nonce,
            scopes: _config!.scopes,
            additionalParameters: additionalParams,
          ),
        );
        if (additionalParams.containsKey(_orgNameParamName)) {
          return additionalParams[_orgNameParamName];
        }
        _saveState(token);
        return token?.accessToken ?? '';
      } catch (ex) {
        return null;
    }
  }

  Uri _buildEndSessionUrl() {
    var uri = (Uri.parse(_serviceConfiguration.endSessionEndpoint!)
        .replace(queryParameters: {
      _postLogoutRedirectParamName: _config!.logoutRedirectUri,
      _redirectParamName: _config!.logoutRedirectUri,
    }));
    return uri;
  }

  Future<bool> _checkToken() async {
    final keys = _store.keys?.keys;
    if (keys != null && keys.isNotEmpty) {
      final key = keys.first;
      var jwt = JsonWebToken.unverified(_store.authState?.accessToken ?? '');

      var jwk = JsonWebKey.fromJson(key.toJson());

      var keyStore = JsonWebKeyStore()
        ..addKey(jwk);

      return await jwt.verify(keyStore);
    }
    return false;
  }

  _saveState(TokenResponse? tokenResponse) {
    _store.authState = AuthState(
        accessToken: tokenResponse?.accessToken,
        idToken: tokenResponse?.idToken,
        accessTokenExpirationDateTime:
        tokenResponse?.accessTokenExpirationDateTime,
        refreshToken: tokenResponse?.refreshToken,
        scope: tokenResponse?.scopes?.join(' '));
    _kindeApi.setBearerAuth(_bearerAuth, tokenResponse?.accessToken ?? '');
  }

  Future<String> _getVersion() async {
    try {
      final fileContent = await rootBundle.loadString(
        "packages/kinde_flutter_sdk/pubspec.yaml",
      );
      final pubspec = Pubspec.parse(fileContent);
      return pubspec.version?.canonicalizedVersion ?? '';
    } catch (exception) {
      return '';
    }
  }

  Future<void> redirect(Uri authorizationUrl) async {
    if (await canLaunchUrl(Uri.parse(authorizationUrl.toString()))) {
      await launchUrl(Uri.parse(authorizationUrl.toString()));
    }
  }

  listen(Uri redirectUrl) {


  }

  Future<String> _webLogin(HashMap<String, String> params, BuildContext context) async {
    String accessToken = '';
    await OAuthWebScreen.start(
        context: context,
        configuration: OAuthConfiguration(
            baseUrl: _config!.authDomain,
            authorizationEndpointUrl: _serviceConfiguration.authorizationEndpoint,
            tokenEndpointUrl: _serviceConfiguration.tokenEndpoint,
            clientId: _config!.authClientId,
            redirectUrl: _config!.loginRedirectUri,
            scopes: _config!.scopes,
            promptValues: const ['login'],
            loginHint: '',
            onCertificateValidate: (certificate) {
              return true;
            },
            refreshBtnVisible: false,
            clearCacheBtnVisible: false,
            onSuccessAuth: (credentials){
              debugPrint("Access Token: ${credentials.accessToken}");
              accessToken = credentials.accessToken;
            },
            onCancel: (){
              debugPrint("User Cancelled Authentication");
            },
            onError: (e){
              throw(e);
            }
        ));
    return accessToken;
  }

  }
