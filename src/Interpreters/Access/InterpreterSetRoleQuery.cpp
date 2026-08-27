#include <Interpreters/InterpreterFactory.h>
#include <Interpreters/Access/InterpreterSetRoleQuery.h>
#include <Parsers/Access/ASTSetRoleQuery.h>
#include <Parsers/Access/ASTRolesOrUsersSet.h>
#include <Access/RolesOrUsersSet.h>
#include <Access/AccessControl.h>
#include <Access/EnabledRolesInfo.h>
#include <Access/SettingsProfilesInfo.h>
#include <Access/User.h>
#include <Core/Settings.h>
#include <IO/WriteHelpers.h>
#include <Interpreters/Context.h>


namespace DB
{
namespace ErrorCodes
{
    extern const int READONLY;
    extern const int SET_NON_GRANTED_ROLE;
}

namespace Setting
{
    extern const SettingsBool force_settings_profile_on_set_role;
    extern const SettingsUInt64 readonly;
}


BlockIO InterpreterSetRoleQuery::execute()
{
    const auto & query = query_ptr->as<const ASTSetRoleQuery &>();
    if (query.kind == ASTSetRoleQuery::Kind::SET_DEFAULT_ROLE)
        setDefaultRole(query);
    else
        setRole(query);
    return {};
}


void InterpreterSetRoleQuery::setRole(const ASTSetRoleQuery & query)
{
    auto session_context = getContext()->getSessionContext();

    if (!getContext()->getSettingsRef()[Setting::force_settings_profile_on_set_role])
    {
        if (query.kind == ASTSetRoleQuery::Kind::SET_ROLE_DEFAULT)
            session_context->setCurrentRolesDefault();
        else
            session_context->setCurrentRoles(RolesOrUsersSet{*query.roles, session_context->getAccessControl()});
        return;
    }

    const UInt64 readonly = getContext()->getSettingsRef()[Setting::readonly];
    if (readonly != 0)
        throw Exception(
            ErrorCodes::READONLY,
            "Cannot execute SET ROLE in readonly mode when force_settings_profile_on_set_role is set (readonly = {})",
            readonly);

    // Resolve the new role set before touching settings
    auto & access_control = session_context->getAccessControl();
    auto user = session_context->getUser();
    std::vector<UUID> new_roles;
    if (query.kind == ASTSetRoleQuery::Kind::SET_ROLE_DEFAULT)
    {
        new_roles = user->granted_roles.findGranted(user->default_roles);
    }
    else
    {
        RolesOrUsersSet new_roles_set{*query.roles, access_control};
        if (new_roles_set.all)
            new_roles = user->granted_roles.findGranted(new_roles_set);
        else
            new_roles = new_roles_set.getMatchingIDs();
    }

    applySettingsProfileAndSetCurrentRoles(*session_context, new_roles);
}


void InterpreterSetRoleQuery::applySettingsProfileAndSetCurrentRoles(Context & target_context, const std::vector<UUID> & new_roles)
{
    auto & access_control = target_context.getAccessControl();
    auto user = target_context.getUser();
    const auto user_id = *target_context.getUserID();

    // Validate grants before settings are modified, so a failure leaves the context intact.
    for (const auto & role_id : new_roles)
    {
        if (!user->granted_roles.isGranted(role_id))
            throw Exception(ErrorCodes::SET_NON_GRANTED_ROLE, "Role {} should be granted to set as a current",
                access_control.tryReadName(role_id).value_or(toString(role_id)));
    }

    applyRoleSettingsProfile(target_context, access_control, user_id, *user, new_roles);
    target_context.setCurrentRoles(new_roles, /* check_grants= */ false);
}


void InterpreterSetRoleQuery::applyRoleSettingsProfile(
    Context & target_context,
    AccessControl & access_control,
    const UUID & user_id,
    const User & user,
    const std::vector<UUID> & new_roles)
{
    auto roles_info = access_control.getEnabledRolesInfo(new_roles, {});
    auto enabled_settings
        = access_control.getEnabledSettingsInfo(user_id, user.settings, roles_info->enabled_roles, roles_info->settings_from_enabled_roles);
    target_context.applySettingsAndReplaceProfiles(
        enabled_settings->settings, enabled_settings->getConstraintsAndProfileIDs());
}


void InterpreterSetRoleQuery::setDefaultRole(const ASTSetRoleQuery & query)
{
    getContext()->checkAccess(query.to_users->collectRequiredGrants(AccessType::ALTER_USER));

    auto & access_control = getContext()->getAccessControl();
    std::vector<UUID> to_users = RolesOrUsersSet{*query.to_users, access_control, getContext()->getUserID()}.getMatchingIDs(access_control);
    RolesOrUsersSet roles_from_query{*query.roles, access_control};

    auto update_func = [&](const AccessEntityPtr & entity, const UUID &) -> AccessEntityPtr
    {
        auto updated_user = typeid_cast<std::shared_ptr<User>>(entity->clone());
        updateUserSetDefaultRoles(*updated_user, roles_from_query);
        return updated_user;
    };

    access_control.update(to_users, update_func);
}


void InterpreterSetRoleQuery::updateUserSetDefaultRoles(User & user, const RolesOrUsersSet & roles_from_query)
{
    if (!roles_from_query.all)
    {
        for (const auto & id : roles_from_query.getMatchingIDs())
        {
            if (!user.granted_roles.isGranted(id))
                throw Exception(ErrorCodes::SET_NON_GRANTED_ROLE, "Role should be granted to set default");
        }
    }
    user.default_roles = roles_from_query;
}

void registerInterpreterSetRoleQuery(InterpreterFactory & factory);
void registerInterpreterSetRoleQuery(InterpreterFactory & factory)
{
    auto create_fn = [] (const InterpreterFactory::Arguments & args)
    {
        return std::make_unique<InterpreterSetRoleQuery>(args.query, args.context);
    };
    factory.registerInterpreter("InterpreterSetRoleQuery", create_fn);
}

}
