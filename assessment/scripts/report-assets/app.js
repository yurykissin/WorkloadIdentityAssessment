(() => {
  'use strict';
  const report = JSON.parse(document.getElementById('report-data').textContent);
  const rows = value => value == null ? [] : Array.isArray(value) ? value : [value];
  const text = value => value == null ? 'Unknown / not collected' : typeof value === 'object' ? JSON.stringify(value, null, 2) : String(value);
  const searchText = value => JSON.stringify(value).toLowerCase();
  const source = id => report.Sources.find(item => item.Id === id);
  const loaded = id => source(id)?.State === 'Loaded';
  const dataset = (id, field) => loaded(id) ? rows(report.Data[id]?.[field]) : [];
  const azureCollected = id => report.Data[id]?.AzureCollected !== false;
  const equalId = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length > 0 && a.toLowerCase() === b.toLowerCase();
  const activityByApp = new Map(dataset('02', 'servicePrincipals').filter(row => row.AppId && row.LastSignIn).map(row => [row.AppId.toLowerCase(), row.LastSignIn]));
  const activityFor = row => row.LastSignIn || activityByApp.get((row.AppId || row.ClientId)?.toLowerCase());
  const creatorText = evidence => {
    if (evidence?.State !== 'Observed creation event') return 'Creator unavailable from retained audit history';
    const actor = evidence.InitiatedBy?.user || evidence.InitiatedBy?.app;
    return `${evidence.InitiatedBy?.user ? 'User' : 'Application'}: ${actor?.displayName || actor?.userPrincipalName || actor?.appId || actor?.id || 'Unknown actor'}; observed ${evidence.CreatedAt}`;
  };
  const node = (tag, className, content) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (content != null) element.textContent = String(content);
    return element;
  };
  const button = (label, action, className) => {
    const element = node('button', className, label);
    element.type = 'button';
    element.addEventListener('click', action);
    return element;
  };
  const input = (label, placeholder) => {
    const element = node('input');
    element.type = 'search';
    element.placeholder = placeholder;
    element.setAttribute('aria-label', label);
    return element;
  };
  const select = (label, options) => {
    const element = node('select');
    element.setAttribute('aria-label', label);
    for (const [value, name] of options) {
      const option = node('option', '', name);
      option.value = value;
      element.append(option);
    }
    return element;
  };
  const fieldLabels = {
    AppObjectId: 'Application object ID', AppId: 'Application (client) ID',
    SpObjectId: 'Service principal object ID', PrincipalId: 'Principal object ID',
    ClientId: 'Managed identity client ID', ResourceId: 'Azure resource ID'
  };
  const fieldLabel = key => fieldLabels[key] || key.replace(/([a-z])([A-Z])/g, '$1 $2');
  function properties(record) {
    const list = node('dl', 'properties');
    for (const [key, value] of Object.entries(record)) {
      const content = node('dd', '', text(value));
      if (typeof value === 'string' && /id$|identifier/i.test(key)) content.append(button('Copy', async () => {
        try { await navigator.clipboard.writeText(value); }
        catch (error) { content.append(node('p', 'notice', `Copy failed: ${error.message}. Select and copy the value manually.`)); }
      }));
      list.append(node('dt', '', fieldLabel(key)), content);
    }
    return list;
  }
  const technicalPanel = document.getElementById('technical-panel');
    function showTechnical(record, title = 'Technical details') {
      document.getElementById('technical-title').textContent = title;
      document.getElementById('technical-content').replaceChildren(properties(record));
      if (!technicalPanel.open) technicalPanel.showModal();
    }
    document.getElementById('technical-close').addEventListener('click', () => technicalPanel.close());
    const permissionRows = () => loaded('05') ? rows(report.Data['05'].NormalizedPermissions || report.Data['05'].GraphPermissions).map(row => ({
      ...row, PermissionType: row.PermissionType || 'Unknown / not collected',
      AdminConsentRequired: row.AdminConsentRequired ?? (row.PermissionType === 'Application' ? true : null),
      ConsentStatus: row.ConsentStatus || (row.GrantState === 'Not granted' ? 'Not granted' : row.GrantState === 'Granted' ? 'Granted (consent scope not collected)' : 'Unknown / not collected'),
      ConfiguredState: row.ConfiguredState || 'Configuration not collected',
      Description: row.Description || row.PermissionDisplayName
    })) : [];
    const permissionColumns = ['SpDisplayName', 'ResourceDisplayName', 'PermissionValue', 'PermissionType', 'Description', 'AdminConsentRequired', 'ConsentStatus', 'ConsentAudience', 'ConfiguredState', 'RiskSeverity', 'RiskLabel', 'ReviewReason'];
  function sameObject(record, evidence) {
    if (evidence.SpObjectId) return equalId(record.SpObjectId || record.PrincipalId || record.principalId, evidence.SpObjectId);
    if (evidence.AppObjectId) return equalId(record.AppObjectId, evidence.AppObjectId);
    if (evidence.PrincipalId || evidence.principalId) return equalId(record.SpObjectId || record.PrincipalId || record.principalId, evidence.PrincipalId || evidence.principalId);
    if (evidence.TargetId) return equalId(record.AppObjectId || record.ResourceId, evidence.TargetId);
    if (evidence.AppId) return equalId(record.AppId || record.ClientId, evidence.AppId);
    return false;
  }
  function sameEvidence(record, evidence) {
    if (!sameObject(record, evidence)) return false;
    const keys = ['KeyId', 'AssignmentId', 'AppRoleId', 'PermissionValue', 'PermissionType', 'ResolutionStatus', 'ResourceAppId', 'ResourceObjectId', 'GrantState', 'ConsentScope', 'ConsentPrincipalId', 'CredentialDisplayName', 'CredentialType', 'StartDateTime', 'EndDateTime', 'RedirectUri', 'FicName', 'RoleName', 'Scope'];
    return keys.every(key => !Object.prototype.hasOwnProperty.call(evidence, key) || record[key] === evidence[key] || (record[key] == null && evidence[key] == null));
  }
  const evidenceFindings = (record, id, field) => report.Findings.filter(finding =>
    finding.Dataset === id && finding.Field === field && rows(finding.AffectedRows).some(evidence => sameEvidence(record, evidence)));
  const issueTone = findings => ['High', 'Med', 'Low', 'Info'].find(severity => findings.some(item => item.Severity === severity))?.replace(/^/, 'issue-').toLowerCase() || '';
  function issueLinks(findings) {
    const links = node('span', `issue-links ${issueTone(findings)}`);
    for (const finding of findings) links.append(button(`${finding.Severity === 'Med' ? 'Medium' : finding.Severity} / ${finding.Outcome} / ${finding.Id}`, () => revealFinding(report.Findings.indexOf(finding))));
    return links;
  }
  function permissionSections(host, permissions, { includeApplication = true, configurationKnown = false, identityLinks = true } = {}) {
    const sections = [
      ['configured', 'Configured permissions', 'Requested in the app registration. The consent status shows whether each permission is actually granted in this tenant.', row => row.ConfiguredState === 'Configured'],
      ['other-granted', 'Other permissions granted', 'Actual tenant grants absent from the collected configured list. This difference alone does not establish unnecessary or unauthorized access.', row => row.ConfiguredState === 'Granted but not configured'],
      ['configuration-unavailable', 'Grants with unavailable configuration', 'Actual grants whose registration configuration is external, unavailable or not collected. These cannot be classified as configured or other granted.', row => !['Configured', 'Granted but not configured'].includes(row.ConfiguredState)]
    ];
    for (const [key, title, description, predicate] of sections) {
      const section = node('section', 'permission-section');
      section.dataset.permissionSection = key;
      const matches = permissions.filter(predicate);
      section.append(node('h4', '', `${title} (${matches.length})`), node('p', 'muted', description));
      if (matches.length) {
        const table = node('div', 'data-table');
        section.append(table);
        createTable(table, { Rows: matches, Columns: permissionColumns.filter(column => column !== 'ConfiguredState' && (includeApplication || column !== 'SpDisplayName')), Dataset: '05', Field: 'NormalizedPermissions', IdentityLinks: identityLinks }, title);
      } else {
        section.append(node('p', 'muted', key === 'configured' && !configurationKnown
          ? 'No configured rows available. Missing configuration is not evidence of an empty requested-permission list.'
          : '0 matching exported permission rows.'));
      }
      host.append(section);
    }
  }
  function availability(id) {
    const item = source(id);
    return node('p', 'notice', `${item.Name}: ${item.State}. ${item.Message}`);
  }

  const tabs = [...document.querySelectorAll('[role="tab"]')];
  function activate(id) {
    if (!tabs.some(tab => tab.dataset.tab === id)) return;
    for (const tab of tabs) {
      const active = tab.dataset.tab === id;
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
    }
    for (const panel of document.querySelectorAll('.view')) panel.hidden = panel.id !== id;
    if (location.hash !== `#${id}`) history.replaceState(null, '', `#${id}`);
    window.scrollTo(0, 0);
  }
  for (const [index, tab] of tabs.entries()) {
    tab.addEventListener('click', () => activate(tab.dataset.tab));
    tab.addEventListener('keydown', event => {
      let target;
      if (event.key === 'ArrowRight') target = (index + 1) % tabs.length;
      if (event.key === 'ArrowLeft') target = (index - 1 + tabs.length) % tabs.length;
      if (event.key === 'Home') target = 0;
      if (event.key === 'End') target = tabs.length - 1;
      if (target != null) {
        event.preventDefault();
        activate(tabs[target].dataset.tab);
        tabs[target].focus();
      }
    });
  }
  window.addEventListener('hashchange', () => activate(location.hash.slice(1)));

  function pager(total, page, size, change) {
    const element = node('div', 'pager');
    const start = total ? page * size + 1 : 0;
    const status = node('span', 'muted', `${start}-${Math.min((page + 1) * size, total)} of ${total}`);
    status.setAttribute('role', 'status');
    const actions = node('div', 'actions');
    const previous = button('Previous', () => change(page - 1));
    const next = button('Next', () => change(page + 1));
    previous.disabled = page === 0;
    next.disabled = (page + 1) * size >= total;
    actions.append(previous, next);
    element.append(status, actions);
    return element;
  }
  function createTable(host, config, title) {
    const allRows = rows(config.Rows).filter(row => row != null);
    const columns = rows(config.Columns);
    const indexed = allRows.map(row => ({ row, query: searchText(row) }));
    let page = 0;
    let sortKey = null;
    let direction = 1;
    const filters = [];
    const toolbar = node('div', 'toolbar');
    const query = input(`${title}: search all exported fields`, 'Search all exported fields...');
    toolbar.append(query);
    for (const field of ['Category', 'SignInAudience', 'CredentialType', 'SecretLifetimeStatus', 'OwnershipStatus', 'Tier', 'RiskOrigin', 'PermissionType', 'ConfiguredState', 'ConsentStatus', 'ConsentAudience', 'Domain', 'Outcome', 'Source', 'IssuerCategory', 'SubjectClassification', 'State', 'OwnerCategory', 'Expired']) {
      if (!allRows.some(row => row[field] != null)) continue;
      const values = [...new Set(allRows.filter(row => row[field] != null).map(row => text(row[field])))].sort();
      const control = select(`${title}: ${fieldLabel(field)}`, [['', `All ${fieldLabel(field).toLowerCase()}`], ...values.map((value, i) => [String(i), value])]);
      filters.push({ field, control, values });
      toolbar.append(control);
      control.addEventListener('change', () => { page = 0; render(); });
    }
    const output = node('div');
    host.replaceChildren(toolbar, output);
    query.addEventListener('input', () => { page = 0; render(); });
    function render() {
      const needle = query.value.trim().toLowerCase();
      let matches = indexed.filter(item => (!needle || item.query.includes(needle)) && filters.every(filter =>
        filter.control.value === '' || text(item.row[filter.field]) === filter.values[Number(filter.control.value)]
      )).map(item => item.row);
      if (sortKey) matches = matches.slice().sort((a, b) => direction * text(a[sortKey]).localeCompare(text(b[sortKey]), undefined, { numeric: true }));
      const scroll = node('div', 'table-scroll');
      const table = node('table');
      table.setAttribute('aria-label', title);
      const head = node('thead');
      const headings = node('tr');
      for (const column of columns) {
        const th = node('th');
        th.scope = 'col';
        th.setAttribute('aria-sort', sortKey === column ? direction === 1 ? 'ascending' : 'descending' : 'none');
        th.append(button(fieldLabel(column), () => {
          direction = sortKey === column ? -direction : 1;
          sortKey = column;
          page = 0;
          render();
        }));
        headings.append(th);
      }
      headings.append(node('th', '', 'Evidence'));
      head.append(headings);
      const body = node('tbody');
      for (const row of matches.slice(page * 50, (page + 1) * 50)) {
        const findings = config.Dataset ? evidenceFindings(row, config.Dataset, config.Field) : [];
        const tr = node('tr', issueTone(findings));
        for (const column of columns) {
          const cell = node('td', '', text(column === 'RiskSeverity' && row[column] === 'Med' ? 'Medium' : row[column]));
          if (column === 'ReviewReason' && row.RiskOrigin) {
            cell.append(node('p', 'muted', `${row.RiskOrigin}; ${row.RiskRuleId || 'no matching rule'}; catalog ${row.RiskCatalogVersion}.`));
            cell.append(node('p', 'muted', row.AccessContext));
            if (row.AZTierStatus && !row.AZTierStatus.startsWith('Not applicable')) cell.append(node('p', 'muted', row.AZTierStatus));
            const appendSource = (url, label) => {
              if (typeof url !== 'string' || !['https://learn.microsoft.com/', 'https://github.com/emiliensocchi/azure-tiering/', 'https://bloodhound.specterops.io/', 'https://www.semperis.com/'].some(prefix => url.startsWith(prefix))) return;
              const link = node('a', '', label);
              link.href = url; link.target = '_blank'; link.rel = 'noopener noreferrer';
              cell.append(link);
            };
            appendSource(row.RiskSourceUrl, row.RiskSourceUrl?.startsWith('https://github.com/') ? 'AZTier source' : 'Microsoft source');
            if (row.CapabilityRuleId && row.CapabilityRuleId !== row.RiskRuleId) {
              const elevated = ['High', 'Med'].includes(row.CapabilitySeverity);
              cell.append(node('p', elevated ? 'notice' : 'muted', `${elevated ? 'Additional capability warning' : 'Capability context'} (${row.CapabilityRuleId}): ${row.CapabilityReason}`));
              appendSource(row.CapabilitySourceUrl, 'Capability source');
            }
            for (const reference of rows(row.RiskReferences)) {
              cell.append(node('p', 'muted', reference.Reason));
              appendSource(reference.Url, `${reference.Source} research`);
            }
          }
          tr.append(cell);
        }
        const detailCell = node('td');
        const detail = button('Technical details', () => showTechnical(row, title));
        detailCell.append(detail);
        const target = identityTarget(row);
        if (target && config.IdentityLinks !== false) {
          const workload = workloadFor.get(target.index);
          const targets = [target, ...workload.items.filter(item => item !== target && (item.type === 'app' || item.type === 'sp'))];
          for (const item of targets) detailCell.append(button(
            item.row.AppObjectId ? 'Open app registration' : item.row.SpObjectId ? 'Open enterprise application' : 'Open managed identity',
            () => revealIdentity(item.index)));
        }
        if (findings.length) detailCell.append(issueLinks(findings));
        tr.append(detailCell);
        body.append(tr);
      }
      table.append(head, body);
      scroll.append(table);
      const total = node('p', 'muted', `${matches.length} matching / ${allRows.length} exported rows`);
      total.setAttribute('role', 'status');
      output.replaceChildren(total);
      if (matches.length) output.append(scroll);
      else output.append(node('p', 'empty', 'No matching exported rows.'));
      output.append(pager(matches.length, page, 50, nextPage => { page = nextPage; render(); }));
    }
    render();
  }
  const identities = [
    ...dataset('02', 'appRegistrations').map(row => ({ kind: 'Application registration', type: 'app', name: row.DisplayName, row })),
    ...dataset('02', 'servicePrincipals').map(row => ({ kind: 'Service principal', type: 'sp', name: row.DisplayName, row })),
    ...dataset('02', 'managedIdentities').map(row => ({ kind: 'Managed identity', type: 'mi', name: row.Name, row: { ...row, Category: 'Managed identity' } })),
    ...rows(report.Data['02']?.WorkloadEvidence?.AgentIdentities?.Records).filter(row => !dataset('02', 'servicePrincipals').some(sp => equalId(sp.SpObjectId, row.id))).map(row => ({ kind: 'Agent identity', type: 'agent', name: row.displayName, row: { ...row, SpObjectId: row.id, AppId: row.appId, DisplayName: row.displayName, Category: 'Agent ID' } })),
    ...rows(report.Data['02']?.WorkloadEvidence?.AgentBlueprints?.Records).filter(row => !dataset('02', 'appRegistrations').some(app => equalId(app.AppObjectId, row.id))).map(row => ({ kind: 'Agent blueprint', type: 'agent', name: row.displayName, row: { ...row, AppObjectId: row.id, AppId: row.appId, DisplayName: row.displayName, Category: 'Agent ID' } }))
  ].map((item, index) => ({ ...item, index, query: searchText(item) }));
  function identityTarget(row) {
    const principalId = row.SpObjectId || row.PrincipalId || row.principalId;
    if (principalId) return identities.find(item => equalId(item.row.SpObjectId || item.row.PrincipalId, principalId));
    if (row.AppObjectId) return identities.find(item => equalId(item.row.AppObjectId, row.AppObjectId));
    if (row.TargetId) return identities.find(item => equalId(item.row.AppObjectId || item.row.ResourceId, row.TargetId));
    return identities.find(item => equalId(item.row.AppId || item.row.ClientId, row.AppId || row.TargetAppId));
  }
  const workloadByKey = new Map();
  const workloadFor = new Map();
  const principalAppIds = new Map(identities.filter(item => item.row.SpObjectId && item.row.AppId).map(item => [item.row.SpObjectId.toLowerCase(), item.row.AppId]));
  for (const item of identities.filter(item => item.type === 'mi' && item.row.PrincipalId && item.row.ClientId)) {
    if (!principalAppIds.has(item.row.PrincipalId.toLowerCase())) principalAppIds.set(item.row.PrincipalId.toLowerCase(), item.row.ClientId);
  }
  for (const item of identities) {
    const principalId = item.row.SpObjectId || item.row.PrincipalId;
    const appId = item.row.AppId || principalAppIds.get(principalId?.toLowerCase()) || item.row.ClientId;
    const key = (appId ? `app:${appId}` : principalId ? `principal:${principalId}` : `${item.type}:${item.row.AppObjectId || item.row.ResourceId || item.index}`).toLowerCase();
    if (!workloadByKey.has(key)) workloadByKey.set(key, { index: workloadByKey.size, items: [], name: item.name });
    const workload = workloadByKey.get(key);
    workload.items.push(item);
    workloadFor.set(item.index, workload);
  }
  const workloads = [...workloadByKey.values()];
  for (const workload of workloads) workload.query = workload.items.map(item => item.query).join(' ');
  let revealIdentity = () => {};
  for (const host of document.querySelectorAll('[data-table]')) {
    const context = { credentials: ['03', 'Credentials'], fic: ['04', 'FederatedCredentials'], stale: ['06', 'ServicePrincipals'] }[host.closest('.view')?.id];
    createTable(host, { ...report.Tables[Number(host.dataset.table)], Dataset: context?.[0], Field: context?.[1] }, host.previousElementSibling?.textContent || 'Exported rows');
  }
  const identityHost = document.getElementById('identity-browser');
  if (identityHost) {
    const toolbar = node('div', 'toolbar');
    const query = input('Search all identities', 'Search names, application IDs, object IDs, resource IDs...');
    query.id = 'identity-search';
    const type = select('Identity type', [['all', 'All identity types'], ['app', 'Application registrations'], ['sp', 'Service principals'], ['mi', 'Managed identity resources'], ['agent', 'Agent ID']]);
    type.id = 'identity-type';
    const categories = [...new Set(identities.map(item => item.row.Category || 'Other / unknown'))].sort();
    const category = select('Identity category', [['all', 'All categories'], ...categories.map(value => [value, `${value} (${workloads.filter(workload => workload.items.some(item => item.row.Category === value)).length} workloads)`])]);
    category.id = 'identity-category';
    category.value = categories.includes('Tenant-managed') ? 'Tenant-managed' : 'all';
    const audience = select('Sign-in audience', [['all', 'All audiences'], ...[...new Set(identities.map(item => item.row.SignInAudience).filter(Boolean))].sort().map(value => [value, value])]);
    const ownerState = select('Owner state', [['all', 'All ownership states'], ['none', 'No owner'], ['owned', 'Has owners'], ['unknown', 'Ownership unknown / not applicable']]);
    const credentialState = select('Credential state', [['all', 'All credential states'], ['expired', 'Expired credentials']]);
    const activityState = select('Activity state', [['all', 'All activity states'], ['observed', 'Observed activity'], ['unknown', 'No observed date / unknown']]);
    const subtype = select('SP subtype', [['all', 'All SP subtypes'], ...[...new Set(identities.map(item => item.row.ServicePrincipalType).filter(Boolean))].sort().map(value => [value, value])]);
    toolbar.append(query, type, category, subtype, audience, ownerState, credentialState, activityState);
    const layout = node('div', 'identity-layout');
    const sidebar = node('div', 'identity-sidebar');
    const list = node('div', 'identity-list');
    list.setAttribute('aria-label', 'Applications and enterprise applications');
    const pagination = node('div');
    const detail = node('div', 'identity-detail');
    detail.id = 'identity-detail';
    detail.tabIndex = -1;
    sidebar.append(list, pagination);
    layout.append(sidebar, detail);
    identityHost.append(toolbar, layout);
    let selected = workloads[0]?.index;
    let page = 0;
    function relatedTable(host, title, id, field, predicate) {
      host.append(node('h4', '', title));
      if (!loaded(id)) { host.append(availability(id)); return; }
      if (field === 'AzureRbac' && !azureCollected(id)) {
        host.append(node('p', 'notice', 'Azure RBAC not collected (Entra-only assessment).'));
        return;
      }
      if (id === '04' && !azureCollected(id)) {
        host.append(node('p', 'notice', 'App-registration federation only; managed-identity federation not collected.'));
      }
      const matches = dataset(id, field).filter(predicate);
      if (!matches.length) { host.append(node('p', 'muted', '0 matching exported records.')); return; }
      const table = node('div', 'data-table');
      host.append(table);
      const columns = {
        Credentials: ['AppDisplayName','CredentialType','CredentialDisplayName','StartDateTime','EndDateTime','SecretLifetimeDays','SecretLifetimeStatus','Expired','LastCredentialSignInDateTime','UsageAssessment'],
        SpCredentials: ['AppDisplayName','CredentialType','CredentialDisplayName','StartDateTime','EndDateTime','SecretLifetimeDays','SecretLifetimeStatus','Expired','UsageAssessment'],
        RedirectUriReviews: ['DisplayName','RedirectUri','RedirectHost','TenantDomainMatch','OwnershipStatus','ReviewReason'],
        FederatedCredentials: ['TargetName','FicName','IssuerCategory','Subject','Audiences'],
        AzureRbac: ['PrincipalDisplayName','RoleName','Scope'],
        DirectoryRoles: ['principalId','roleDefinitionId','directoryScopeId']
      };
      createTable(table, { Rows: matches, Columns: columns[field] || ['DisplayName'], Dataset: id, Field: field, IdentityLinks: false }, title);
    }
    function exportedValue(value) {
      if (value == null || typeof value !== 'object') return node('span', '', text(value));
      if (Array.isArray(value)) {
        if (!value.length) return node('span', 'muted', 'None exported (empty list)');
        const list = node('ul', 'exported-list');
        for (const entry of value) {
          const item = node('li');
          item.append(exportedValue(entry));
          list.append(item);
        }
        return list;
      }
      if (!Object.keys(value).length) return node('span', 'muted', 'Empty exported object');
      const list = node('dl', 'nested-properties');
      for (const [key, entry] of Object.entries(value)) {
        const content = node('dd');
        content.append(exportedValue(entry));
        list.append(node('dt', '', fieldLabel(key)), content);
      }
      return list;
    }
    function settingProperties(record, keys) {
      const list = node('dl', 'properties exported-settings');
      const controlsByField = {
        OwnerCount: ['WI.OWN.1', 'WI.OWN.2', 'WI.OWN.3'], Owners: ['WI.OWN.1', 'WI.OWN.2', 'WI.OWN.3'],
        LastSignIn: ['WI.LIFE.1'], DaysSinceLastSignIn: ['WI.LIFE.1'], ActivityStatus: ['WI.LIFE.1'],
        HasImplicitGrantEnabled: ['WI.APP.2'], ImplicitGrantSettings: ['WI.APP.2'],
        RedirectUris: ['WI.APP.4']
      };
      for (const key of keys) {
        const findings = report.Findings.filter(finding => controlsByField[key]?.includes(finding.Id) && rows(finding.AffectedRows).some(evidence => sameObject(record, evidence)));
        const content = node('dd', issueTone(findings));
        content.dataset.setting = key;
        content.append(key === 'CreationEvidence' ? node('p', 'muted', creatorText(record[key])) : node('span'));
        content.append(exportedValue(record[key]));
        if (findings.length) content.append(issueLinks(findings));
        list.append(node('dt', '', fieldLabel(key)), content);
      }
      return list;
    }
    function objectPanel(item, title) {
      const panel = node('section', 'panel counterpart-panel');
      panel.tabIndex = -1;
      panel.dataset.identity = String(item.index);
      panel.setAttribute('aria-label', `${title}: ${item.name || 'Unnamed identity'}`);
      panel.append(node('h4', '', title), node('h5', '', item.name || 'Unnamed identity'));
      const row = item.row;
      const coreKeys = ['SignInAudience', 'AccountEnabled', 'OwnerCount', 'CreatedDateTime', 'CreationEvidence', 'LastSignIn', 'ActivityStatus', 'DaysSinceLastSignIn'].filter(key => Object.hasOwn(row, key));
      panel.append(settingProperties(row, coreKeys));
      if (row.SpObjectId) panel.append(node('p', 'muted', 'Observed service-principal activity is not necessarily a successful login or proof of every API operation. Credential use is assessed separately.'));
      panel.append(button('Technical details and identifiers', () => showTechnical(row, `${title}: ${item.name || 'Unnamed identity'}`)));
      const groups = [
        ['Ownership', ['OwnerCount', 'Owners']],
        ['Authentication and audience', ['SignInAudience', 'RedirectUris', 'RedirectUriCount', 'ImplicitGrantSettings', 'HasImplicitGrantEnabled', 'InstancePropertyLock']],
        ['API definition and requested access', ['RequiredResourceAccess', 'IdentifierUris', 'RequestedAccessTokenVersion', 'AppRoleCount', 'OAuth2ScopeCount', 'AppRoleAssignmentCount']],
        ['Credentials and federation metadata', ['PasswordCredentials', 'KeyCredentials', 'PasswordCredentialCount', 'ActivePasswordCredentialCount', 'KeyCredentialCount', 'ActiveKeyCredentialCount', 'FederatedCredentialCount']],
        ['Creation and observed activity', ['CreatedDateTime', 'AgeInDays', 'CreationEvidence', 'LastSignIn', 'DaysSinceLastSignIn', 'ActivityStatus', 'ActivityFlows', 'NeverSignedIn']]
      ];
      const grouped = new Set(groups.flatMap(([, keys]) => keys));
      groups.push(['Other exported settings and identifiers', Object.keys(row).filter(key => !grouped.has(key))]);
      panel.append(node('p', 'muted', 'All exported settings are available below. Settings absent from this snapshot have not been assessed.'));
      for (const [label, keys] of groups) {
        const exported = keys.filter(key => Object.hasOwn(row, key));
        if (!exported.length) continue;
        const group = node('details', 'settings-group');
        group.append(node('summary', '', label), settingProperties(row, exported));
        panel.append(group);
      }
      return panel;
    }
    function focusObject(index) {
      const panel = detail.querySelector(`.counterpart-panel[data-identity="${index}"]`);
      for (const item of detail.querySelectorAll('.counterpart-panel')) item.classList.toggle('counterpart-focused', item === panel);
      panel?.focus({ preventScroll: true });
      panel?.scrollIntoView({ block: 'nearest' });
    }
    function renderDetail() {
      const workload = workloads[selected];
      if (!workload) { detail.replaceChildren(node('p', 'empty', 'No exported application selected.')); return; }
      const apps = workload.items.filter(item => item.row.AppObjectId);
      const sps = workload.items.filter(item => item.row.SpObjectId);
      const managed = workload.items.filter(item => item.type === 'mi');
      const principalIds = [...sps.map(item => item.row.SpObjectId), ...managed.map(item => item.row.PrincipalId)];
      const credentials = [...dataset('03', 'Credentials').filter(row => apps.some(item => equalId(row.AppObjectId, item.row.AppObjectId))),
        ...dataset('02', 'SpCredentials').filter(row => principalIds.some(id => equalId(row.SpObjectId, id)))];
      const expired = credentials.filter(row => row.Expired === true);
      detail.replaceChildren(node('h3', '', workload.name || 'Unnamed application'));
      const badges = node('div', 'identity-badges');
      for (const category of new Set(workload.items.map(item => item.row.Category || 'Other / unknown'))) badges.append(node('span', 'badge', category));
      if (expired.length) {
        const findings = credentials.flatMap(row => [...evidenceFindings(row, '03', 'Credentials'), ...evidenceFindings(row, '02', 'SpCredentials')]);
        badges.append(button(`${expired.length} expired credential(s)`, () => {
          const first = detail.querySelector('[data-related="credentials"]');
          first?.scrollIntoView({ block: 'start' });
        }, `badge ${issueTone(findings)}`));
      }
      detail.append(badges, button('View all findings', () => {
        severity.value = 'all'; findingQuery.value = ''; filterFindings(); activate('findings');
      }));
      const pair = node('div', 'counterpart-pair');
      const appColumn = node('div', 'counterpart-column');
      const spColumn = node('div', 'counterpart-column');
      pair.append(appColumn, spColumn);
      if (apps.length) {
        for (const item of apps) appColumn.append(objectPanel(item, item.kind === 'Agent blueprint' ? 'App registration / Agent blueprint' : 'App registration'));
      } else {
        const external = sps.some(item => ['Microsoft-owned', 'External / third-party'].includes(item.row.Category));
        const message = managed.length || sps.some(item => item.row.ServicePrincipalType === 'ManagedIdentity')
          ? 'Not applicable: managed identities do not have an app registration.'
          : external ? 'External app definition: no registration exported from this tenant. Its requested permissions and settings are unavailable here.'
            : 'No matching app registration exported. Missing definition evidence is not proof that no registration exists elsewhere.';
        appColumn.append(node('h4', '', 'App registration'), node('p', 'empty counterpart-state', message));
      }
      if (sps.length) {
        for (const item of sps) spColumn.append(objectPanel(item, item.kind === 'Agent identity' ? 'Enterprise app / Agent identity' : 'Enterprise app (service principal)'));
      } else {
        spColumn.append(node('h4', '', 'Enterprise app (service principal)'), node('p', 'empty counterpart-state', 'No matching local enterprise application exported. This does not establish global non-use of a multitenant app or absence from an incomplete collection.'));
      }
      detail.append(pair);
      for (const item of managed) detail.append(objectPanel(item, 'Managed identity resource'));
      const related = node('div', 'panel application-access');
      related.append(node('p', 'muted', 'Related records use exported application, object, principal and resource IDs, never display names. The panels show separate directory objects, not separate deployed applications.'));
      const credentialHost = node('section');
      credentialHost.dataset.related = 'credentials';
      related.append(credentialHost);
      relatedTable(credentialHost, 'Application credentials', '03', 'Credentials', row =>
        apps.some(item => equalId(row.AppObjectId, item.row.AppObjectId)));
      if (dataset('02','SpCredentials').some(row => principalIds.some(id => equalId(row.SpObjectId, id)))) {
        relatedTable(credentialHost, 'Service principal credentials', '02', 'SpCredentials', row => principalIds.some(id => equalId(row.SpObjectId, id)));
      }
      relatedTable(related, 'Federated credentials', '04', 'FederatedCredentials', row =>
        row.Target === 'appRegistration' && apps.some(item => equalId(row.TargetId, item.row.AppObjectId)) ||
        row.Target === 'userAssignedMI' && managed.some(item => equalId(row.TargetId, item.row.ResourceId)));
      if (apps.length) {
        if (apps.some(item => Array.isArray(item.row.RedirectUris))) {
          relatedTable(related, 'Redirect URI ownership review', '02', 'RedirectUriReviews', row =>
            apps.some(item => equalId(row.AppObjectId, item.row.AppObjectId)));
          related.append(node('p', 'muted', 'Current domain and endpoint ownership require manual confirmation, including tenant verified-domain matches. No network probes are performed; an unverified domain is not a confirmed takeover.'));
        } else related.append(node('p', 'notice', 'Redirect URI ownership not assessed: redirect URI inventory was not collected in this snapshot.'));
      }
      related.append(node('h4', '', 'API permissions for this application'));
      if (loaded('05')) {
        permissionSections(related, permissionRows().filter(row => principalIds.some(id => equalId(row.SpObjectId, id)) ||
          apps.some(item => equalId(row.AppObjectId, item.row.AppObjectId))), {
          includeApplication: false, configurationKnown: apps.some(item => Array.isArray(item.row.RequiredResourceAccess)), identityLinks: false
        });
      } else related.append(availability('05'));
      relatedTable(related, 'Azure RBAC assignments', '05', 'AzureRbac', row => principalIds.some(id => equalId(row.PrincipalId, id)));
      const directoryRoles = rows(report.Data['02']?.WorkloadEvidence?.DirectoryRoles?.Records).filter(row => principalIds.some(id => equalId(row.principalId, id)));
      if (directoryRoles.length) {
        related.append(node('h4', '', 'Directory role assignments'));
        const table = node('div', 'data-table');
        related.append(table);
        createTable(table, { Rows: directoryRoles, Columns: ['principalId', 'roleDefinitionId', 'directoryScopeId'], Dataset: '02', Field: 'WorkloadEvidence', IdentityLinks: false }, 'Directory role assignments');
      }
      detail.append(related);
    }
    function renderList() {
      const needle = query.value.trim().toLowerCase();
      const matches = workloads.filter(workload => workload.items.some(item =>
        (type.value === 'all' || item.type === type.value) &&
        (category.value === 'all' || item.row.Category === category.value) &&
        (subtype.value === 'all' || item.row.ServicePrincipalType === subtype.value) &&
        (audience.value === 'all' || item.row.SignInAudience === audience.value) &&
        (ownerState.value === 'all' || (ownerState.value === 'none' ? item.row.OwnerCount === 0 : ownerState.value === 'owned' ? item.row.OwnerCount > 0 : item.row.OwnerCount == null))) &&
        (activityState.value === 'all' || (activityState.value === 'observed' ? workload.items.some(item => !!activityFor(item.row)) : workload.items.every(item => !activityFor(item.row)))) &&
        (credentialState.value === 'all' || [...dataset('03','Credentials'), ...dataset('02','SpCredentials')].some(row => row.Expired === true && workload.items.some(item => sameObject(item.row, row)))) &&
        (!needle || workload.query.includes(needle)));
      if (!matches.some(item => item.index === selected)) {
        selected = matches[0]?.index;
        renderDetail();
      }
      list.replaceChildren();
      const table = node('table', 'workload-table');
      table.setAttribute('aria-label', 'Applications');
      const head = node('thead');
      const headings = node('tr');
      headings.append(node('th', '', 'Name'));
      head.append(headings);
      const body = node('tbody');
      for (const workload of matches.slice(page * 50, (page + 1) * 50)) {
        const row = node('tr', selected === workload.index ? 'selected-workload' : '');
        const name = node('td');
        const control = button(workload.name || 'Unnamed application', () => { selected = workload.index; renderList(); renderDetail(); }, 'identity-item');
        control.dataset.workload = String(workload.index);
        control.setAttribute('aria-pressed', String(selected === workload.index));
        name.append(control);
        row.append(name);
        body.append(row);
      }
      table.append(head, body);
      if (matches.length) list.append(table);
      else list.append(node('p', 'empty', 'No matching exported applications.'));
      pagination.replaceChildren(pager(matches.length, page, 50, nextPage => { page = nextPage; renderList(); }));
    }
    for (const control of [query, type, category, subtype, audience, ownerState, credentialState, activityState]) control.addEventListener(control === query ? 'input' : 'change', () => { page = 0; renderList(); });
    revealIdentity = index => {
      query.value = '';
      type.value = 'all';
      category.value = 'all'; subtype.value = 'all'; audience.value = 'all'; ownerState.value = 'all'; credentialState.value = 'all'; activityState.value = 'all';
      selected = workloadFor.get(index)?.index;
      page = Math.floor(selected / 50);
      activate('inventory');
      renderList();
      renderDetail();
      focusObject(index);
    };
    renderList();
    renderDetail();
  }

  const findingPanel = document.getElementById('findings');
  function expandFinding(group, expanded) {
    const toggle = group.querySelector('[data-finding-toggle]');
    document.getElementById(toggle.getAttribute('aria-controls')).hidden = !expanded;
    toggle.setAttribute('aria-expanded', String(expanded));
    toggle.setAttribute('aria-label', `${expanded ? 'Hide' : 'Show'} details for ${report.Findings[Number(group.dataset.findingIndex)].Id}`);
    toggle.textContent = expanded ? 'Hide details' : 'Details';
    const shortcut = group.querySelector('[data-finding-affected]');
    shortcut.setAttribute('aria-expanded', String(expanded && !group.querySelector('.finding-evidence').hidden));
  }
  for (const toggle of findingPanel.querySelectorAll('[data-finding-toggle]')) {
    toggle.addEventListener('click', () => expandFinding(toggle.closest('.finding'), toggle.getAttribute('aria-expanded') !== 'true'));
  }
  for (const control of findingPanel.querySelectorAll('[data-evidence]')) {
    control.addEventListener('click', () => {
      const finding = report.Findings[Number(control.dataset.evidence)];
      const host = control.nextElementSibling;
      host.hidden = !host.hidden;
      control.setAttribute('aria-expanded', String(!host.hidden));
      control.textContent = `${host.hidden ? 'View' : 'Hide'} affected objects (${rows(finding.AffectedRows).length})`;
      control.closest('.finding').querySelector('[data-finding-affected]').setAttribute('aria-expanded', String(!host.hidden));
      if (!host.hidden && !host.children.length) createTable(host, {
        Rows: finding.AffectedRows,
        Dataset: finding.Dataset, Field: finding.Field,
        Columns: ['DisplayName','AppDisplayName','SpDisplayName','PermissionValue','PermissionType','ConsentAudience','RiskSeverity','RiskLabel','ReviewReason','CredentialDisplayName','StartDateTime','EndDateTime','SecretLifetimeDays','SecretLifetimeStatus','RedirectUri','RedirectHost','TenantDomainMatch','OwnershipStatus','OwnerCount'].filter(key => rows(finding.AffectedRows).some(row => row[key] != null))
      }, `${finding.Id} affected objects`);
    });
  }
  for (const shortcut of findingPanel.querySelectorAll('[data-finding-affected]')) {
    shortcut.addEventListener('click', () => {
      const group = shortcut.closest('.finding');
      expandFinding(group, true);
      if (group.querySelector('.finding-evidence').hidden) group.querySelector('[data-evidence]').click();
    });
  }
  const coverage = document.getElementById('control-coverage');
  createTable(coverage, { Rows: report.Assessment.Results, Columns: ['Id','ExternalId','Domain','Title','Severity','Outcome','Source','Strength','AffectedCount','EligibleCount','UnknownCount'] }, 'Control coverage');
  coverage.append(button('Baseline applicability and versions', () => showTechnical({
    CatalogVersion: report.Assessment.CatalogVersion, BaselineRevision: report.Assessment.BaselineRevision, Applicability: report.Assessment.BaselineApplicability
  }, 'Baseline coverage')));
  coverage.append(button('Permission risk catalog and sources', () => {
    const catalog = report.Assessment.PermissionRisk;
    const az = catalog.AZTier;
    const content = document.getElementById('technical-content');
    document.getElementById('technical-title').textContent = 'Permission risk catalog';
    content.replaceChildren(node('p', 'notice', catalog.Limitations), properties({
      PermissionCatalogVersion: catalog.Version, VerifiedOn: catalog.VerifiedOn,
      AZTierRevision: az.Revision, ReviewedListLastChanged: az.TieredLastChanged,
      UntieredListLastChanged: az.UntieredLastChanged, Maintenance: az.Maintenance,
      ReviewedSource: az.TieredSourceUrl, UntieredSource: az.UntieredSourceUrl,
      Attribution: az.Attribution
    }));
    content.append(node('h3', '', 'Microsoft and toolkit fallback rules'));
    const rules = node('div', 'data-table');
    content.append(rules);
    createTable(rules, { Rows: catalog.Rules.map(rule => ({ ...rule, SourceUrl: catalog.Sources[rule.Source] })), Columns: ['Id', 'Resource', 'Types', 'Tier', 'Origin', 'Reason'] }, 'Fallback permission rules');
    content.append(node('h3', '', 'AZTier Graph application-permission mappings'));
    const mappings = node('div', 'data-table');
    content.append(mappings);
    createTable(mappings, {
      Rows: [
        ...az.TieredPermissions.map(row => ({ ...row, RiskSeverity: az.SeverityMapping[row.Tier].Severity, State: 'Reviewed', SourceUrl: az.TieredSourceUrl })),
        ...az.UntieredPermissions.map(row => ({ ...row, Tier: 'Not assigned', RiskSeverity: az.UntieredSeverity, State: 'Untiered / Unrated', SourceUrl: az.UntieredSourceUrl }))
      ],
      Columns: ['PermissionValue', 'Tier', 'RiskSeverity', 'State', 'DetectedOn']
    }, 'AZTier application mappings');
    const license = node('details');
    license.append(node('summary', '', `Source-data license: ${az.License}`), properties({ LicenseText: az.LicenseText }));
    content.append(license, button('Raw permission catalog JSON', () => showTechnical(catalog, 'Raw permission catalog')));
    if (!technicalPanel.open) technicalPanel.showModal();
  }));
  const capabilityRows = [
    ...Object.entries(report.Data['02']?.WorkloadEvidence || {}),
    ['SP activity', report.Data['02']?.SignInActivity],
    ['Credential activity', report.Data['03']?.CredentialActivity],
    ['Delegated grants', report.Data['05']?.DelegatedGrantEvidence]
  ].filter(([, value]) => value).map(([name, value]) => ({
    Capability: name, ...value, RecordCount: value.RecordCount ?? (value.Records == null ? null : rows(value.Records).length)
  }));
  coverage.append(node('h3', '', 'Optional evidence capabilities'));
  if (capabilityRows.length) {
    const capabilityTable = node('div', 'data-table');
    coverage.append(capabilityTable);
    createTable(capabilityTable, { Rows: capabilityRows, Columns: ['Capability','State','ApiVersion','RecordCount','CollectedAt','Message'] }, 'Evidence capabilities');
  } else {
    coverage.append(node('p', 'notice', 'Legacy snapshot: capability-level states were not collected. File presence cannot establish API/query completeness.'));
  }
  const permissionView = document.getElementById('permissions');
  if (loaded('05')) {
    const panel = node('div', 'panel');
    panel.append(node('h3', '', 'API permissions by application and resource'),
      node('p', 'muted', 'Configured requests and actual tenant grants are different evidence. Removing a configured request is not the same as revoking a grant. Application access and delegated consent are labelled separately; see consent status for tenant-wide versus user-specific grants. Technical IDs remain in the side panel.'));
    permissionView.querySelector('h2').after(panel);
    permissionSections(panel, permissionRows().sort((a,b) => `${a.SpDisplayName}|${a.ResourceDisplayName}`.localeCompare(`${b.SpDisplayName}|${b.ResourceDisplayName}`)));
  }
  const findingControls = node('div', 'toolbar');
  const findingQuery = input('Search findings and recommendations', 'Search findings and recommendations...');
  const severity = select('Finding severity', [['all', 'All severities'], ['High', 'High'], ['Med', 'Medium'], ['Low', 'Low'], ['Info', 'Information']]);
  severity.id = 'finding-severity';
  const findingCount = node('span', 'muted');
  findingCount.setAttribute('role', 'status');
  findingControls.append(findingQuery, severity, findingCount);
  findingPanel.querySelector('h2').after(findingControls);
  const findingGroups = [...findingPanel.querySelectorAll('.finding')];
  const noMatches = node('p', 'empty', 'No matching findings.');
  findingPanel.append(noMatches);
  const incomplete = report.Sources.some(item => item.State !== 'Loaded');
  findingPanel.insertBefore(node('p', incomplete ? 'notice' : 'muted', incomplete
    ? 'Some datasets are unavailable or partial. Findings cover loaded datasets only; unassessed areas are not an all-clear result.'
    : 'Findings have explicit sources and affected evidence. Review candidates are not confirmed unnecessary access. See Control coverage for unassessed domains.'), findingControls);
  function filterFindings() {
    const needle = findingQuery.value.trim().toLowerCase();
    let count = 0;
    for (const group of findingGroups) {
      group.hidden = (severity.value !== 'all' && group.dataset.severity !== severity.value) || !group.textContent.toLowerCase().includes(needle);
      if (!group.hidden) count++;
    }
    findingCount.textContent = `${count} of ${findingGroups.length} findings`;
    noMatches.hidden = count !== 0 || findingGroups.length === 0;
    const table = findingPanel.querySelector('.findings-table-wrap');
    if (table) table.hidden = count === 0;
  }
  findingQuery.addEventListener('input', filterFindings);
  severity.addEventListener('change', filterFindings);
  filterFindings();
  function revealFinding(index) {
    severity.value = 'all';
    findingQuery.value = '';
    filterFindings();
    activate('findings');
    const group = findingPanel.querySelector(`[data-finding-index="${index}"]`);
    if (group) {
      expandFinding(group, true);
      group.focus();
    }
  }

  const tenant = report.Data['01']?.TenantInfo || {};
  document.title = `Workload Identity Assessment - ${tenant.DisplayName || 'Tenant unavailable'}`;
  document.getElementById('tenant-meta').textContent = [
    tenant.DisplayName || 'Tenant unavailable', tenant.PrimaryDomain, tenant.TenantId,
    `Generated: ${report.GeneratedAt}`
  ].filter(Boolean).join(' / ');
  document.getElementById('snapshot-meta').replaceWith(properties({
    'Run directory': report.RunDirectory, 'Generated (UTC)': report.GeneratedAt,
    'Assessment scope': report.AssessmentScope === 'Entra' ? 'Entra only - Azure checks not collected' : 'Entra + Azure',
    'Export files loaded': `${report.Sources.filter(item => item.State === 'Loaded').length} / 8`,
    'Collection completeness': 'Not established by file presence'
  }));
  const cards = document.getElementById('overview-cards');
  const metrics = [
    ['Application registrations', loaded('02') ? dataset('02', 'appRegistrations').length : null, 'inventory', 'app'],
    ['Service principals', loaded('02') ? dataset('02', 'servicePrincipals').length : null, 'inventory', 'sp'],
    ['Managed identities (Azure)', loaded('02') ? azureCollected('02') ? dataset('02', 'managedIdentities').length : 'Not collected' : null, 'inventory', 'mi'],
    ['Credential records', loaded('03') ? dataset('03', 'Credentials').length : null, 'credentials'],
    ['High findings', report.Findings.filter(item => item.Severity === 'High').length, 'findings', 'High'],
    ['Medium findings', report.Findings.filter(item => item.Severity === 'Med').length, 'findings', 'Med']
  ];
  for (const [label, value, tab, filter] of metrics) {
    const card = button('', () => {
      activate(tab);
      if (tab === 'inventory' && identityHost) {
        document.getElementById('identity-type').value = filter;
        document.getElementById('identity-category').value = 'all';
        document.getElementById('identity-search').value = '';
        document.getElementById('identity-type').dispatchEvent(new Event('change'));
      }
      if (tab === 'findings') { severity.value = filter; findingQuery.value = ''; filterFindings(); }
    }, `card tone-${(filter || '').toLowerCase()}`);
    card.append(node('span', 'card-value', value == null ? 'Unavailable' : value), node('span', 'card-label', label));
    if (value === 'Not collected') card.disabled = true;
    cards.append(card);
  }
  for (const level of ['High', 'Med', 'Low', 'Info']) {
    const count = report.Findings.filter(item => item.Severity === level).length;
    const control = button('', () => { activate('findings'); severity.value = level; findingQuery.value = ''; filterFindings(); }, `severity-row sev-${level.toLowerCase()}`);
    const bar = node('span', 'bar');
    const fill = node('span');
    fill.style.width = `${report.Findings.length ? count / report.Findings.length * 100 : 0}%`;
    bar.append(fill);
    control.append(node('span', 'sev', level), bar, node('strong', '', count));
    document.getElementById('severity-summary').append(control);
  }
  const sourceTable = node('table');
  sourceTable.setAttribute('aria-label', 'Source data availability');
  const sourceHead = node('thead');
  const sourceHeadings = node('tr');
  for (const label of ['Dataset', 'File state', 'Collected at', 'Source / collection context']) sourceHeadings.append(node('th', '', label));
  sourceHead.append(sourceHeadings);
  const sourceBody = node('tbody');
  for (const item of report.Sources) {
    const row = node('tr');
    const name = node('td', '', `${item.Id} / ${item.Name}`);
    const status = node('td');
    status.append(node('span', `badge ${item.State.toLowerCase()}`, item.State));
    const context = node('td', '', `${item.FileName || 'No source file'} - ${item.Message}`);
    row.append(name, status, node('td', '', item.CollectedAt || 'Not exported'), context);
    sourceBody.append(row);
  }
  sourceTable.append(sourceHead, sourceBody);
  document.getElementById('source-table').append(sourceTable);
  const rawPanel = document.getElementById('raw');
  rawPanel.querySelector('h2').after(properties({ 'Selected run': report.RunDirectory, 'Embedded datasets': Object.keys(report.RawData).length }));
  for (const table of document.querySelectorAll('#tenant > table')) {
    const scroll = node('div', 'table-scroll');
    table.replaceWith(scroll);
    scroll.append(table);
  }
  if (report.Data['06']?.SignInDataAvailable === false) {
    document.getElementById('stale').querySelector('h2').after(node('p', 'notice', 'The export records SignInDataAvailable = false. Sign-in-derived hygiene results have incomplete evidence.'));
  }

  const global = document.getElementById('global-search');
  const results = document.getElementById('global-results');
  const searchIndex = [
    ...identities.map(item => ({ query: item.query, label: item.name || 'Unnamed identity', kind: item.kind, action: () => revealIdentity(item.index) })),
    ...report.Findings.map((item, index) => ({ query: searchText(item), label: item.Title, kind: `${item.Severity} finding`, action: () => revealFinding(index) }))
  ];
  global.addEventListener('input', () => {
    const query = global.value.trim().toLowerCase();
    results.replaceChildren();
    results.hidden = !query;
    if (!query) return;
    const matches = searchIndex.filter(item => item.query.includes(query));
    results.append(node('p', 'muted', matches.length ? `${matches.length} matches${matches.length > 30 ? ' / showing first 30; refine your search' : ''}` : 'No matching identities or findings.'));
    for (const match of matches.slice(0, 30)) {
      const control = button('', () => { results.hidden = true; match.action(); });
      control.append(node('span', 'search-type', match.kind), node('span', '', match.label));
      results.append(control);
    }
  });
  global.addEventListener('keydown', event => {
    if (event.key === 'Escape') results.hidden = true;
    if (event.key === 'ArrowDown' && !results.hidden) {
      event.preventDefault();
      results.querySelector('button')?.focus();
    }
    if (event.key === 'Enter' && !results.hidden) {
      event.preventDefault();
      results.querySelector('button')?.click();
    }
  });
  results.addEventListener('keydown', event => {
    if (event.key === 'Escape') { results.hidden = true; global.focus(); }
    const buttons = [...results.querySelectorAll('button')];
    const index = buttons.indexOf(document.activeElement);
    if (event.key === 'ArrowDown' && index >= 0) { event.preventDefault(); buttons[(index + 1) % buttons.length].focus(); }
    if (event.key === 'ArrowUp' && index >= 0) { event.preventDefault(); if (index === 0) global.focus(); else buttons[index - 1].focus(); }
  });
  document.addEventListener('click', event => { if (!event.target.closest('.gsearch')) results.hidden = true; });
  activate(tabs.some(tab => tab.dataset.tab === location.hash.slice(1)) ? location.hash.slice(1) : 'overview');
})();
