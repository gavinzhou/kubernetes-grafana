local k = import 'ksonnet/ksonnet.beta.3/k.libsonnet';

{
  _config+:: {
    namespace: 'default',

    versions+:: {
      grafana: '6.1.4',
    },

    imageRepos+:: {
      grafana: 'grafana/grafana',
    },

    grafana+:: {
      dashboards: {},
      datasources: [{
        name: 'prometheus',
        type: 'prometheus',
        access: 'proxy',
        orgId: 1,
        url: 'http://prometheus-k8s.' + $._config.namespace + '.svc:9090',
        version: 1,
        editable: false,
      }],
      config: null,
      plugins: [],
    },
  },
  grafanaDashboards: {},
  grafana+: {
    [if $._config.grafana.config != null then 'config']:
      local secret = k.core.v1.secret;
      secret.new('grafana-config', { 'grafana.ini': std.base64(std.manifestIni($._config.grafana.config)) }) +
      secret.mixin.metadata.withNamespace($._config.namespace),
    dashboardDefinitions:
      local configMap = k.core.v1.configMap;
      [
        local dashboardName = 'grafana-dashboard-' + std.strReplace(name, '.json', '');
        configMap.new(dashboardName, { [name]: std.manifestJsonEx($._config.grafana.dashboards[name], '    ') }) +
        configMap.mixin.metadata.withNamespace($._config.namespace)

        for name in std.objectFields($._config.grafana.dashboards)
      ],
    dashboardSources:
      local configMap = k.core.v1.configMap;
      local dashboardSources = import 'configs/dashboard-sources/dashboards.libsonnet';

      configMap.new('grafana-dashboards', { 'dashboards.yaml': std.manifestJsonEx(dashboardSources, '    ') }) +
      configMap.mixin.metadata.withNamespace($._config.namespace),
    dashboardDatasources:
      local secret = k.core.v1.secret;
      secret.new('grafana-datasources', { 'prometheus.yaml': std.base64(std.manifestJsonEx({
        apiVersion: 1,
        datasources: $._config.grafana.datasources,
      }, '    ')) }) +
      secret.mixin.metadata.withNamespace($._config.namespace),
    service:
      local service = k.core.v1.service;
      local servicePort = k.core.v1.service.mixin.spec.portsType;

      local grafanaServiceNodePort = servicePort.newNamed('http', 3000, 'http');

      service.new('grafana', $.grafana.deployment.spec.selector.matchLabels, grafanaServiceNodePort) +
      service.mixin.metadata.withNamespace($._config.namespace),
    serviceAccount:
      local serviceAccount = k.core.v1.serviceAccount;
      serviceAccount.new('grafana') +
      serviceAccount.mixin.metadata.withNamespace($._config.namespace),
    deployment:
      local deployment = k.apps.v1beta2.deployment;
      local container = k.apps.v1beta2.deployment.mixin.spec.template.spec.containersType;
      local volume = k.apps.v1beta2.deployment.mixin.spec.template.spec.volumesType;
      local containerPort = container.portsType;
      local containerVolumeMount = container.volumeMountsType;
      local podSelector = deployment.mixin.spec.template.spec.selectorType;
      local env = container.envType;

      local targetPort = 3000;
      local podLabels = { app: 'grafana' };

      local configVolumeName = 'grafana-config';
      local configSecretName = 'grafana-config';
      local configVolume = volume.withName(configVolumeName) + volume.mixin.secret.withSecretName(configSecretName);
      local configVolumeMount = containerVolumeMount.new(configVolumeName, '/etc/grafana');

      local storageVolumeName = 'grafana-storage';
      local storageVolume = volume.fromEmptyDir(storageVolumeName);
      local storageVolumeMount = containerVolumeMount.new(storageVolumeName, '/var/lib/grafana');

      local datasourcesVolumeName = 'grafana-datasources';
      local datasourcesSecretName = 'grafana-datasources';
      local datasourcesVolume = volume.withName(datasourcesVolumeName) + volume.mixin.secret.withSecretName(datasourcesSecretName);
      local datasourcesVolumeMount = containerVolumeMount.new(datasourcesVolumeName, '/etc/grafana/provisioning/datasources');

      local dashboardsVolumeName = 'grafana-dashboards';
      local dashboardsConfigMapName = 'grafana-dashboards';
      local dashboardsVolume = volume.withName(dashboardsVolumeName) + volume.mixin.configMap.withName(dashboardsConfigMapName);
      local dashboardsVolumeMount = containerVolumeMount.new(dashboardsVolumeName, '/etc/grafana/provisioning/dashboards');

      local volumeMounts =
        [
          storageVolumeMount,
          datasourcesVolumeMount,
          dashboardsVolumeMount,
        ] +
        [
          local dashboardName = std.strReplace(name, '.json', '');
          containerVolumeMount.new('grafana-dashboard-' + dashboardName, '/grafana-dashboard-definitions/0/' + dashboardName)
          for name in std.objectFields($._config.grafana.dashboards)
        ] +
        if $._config.grafana.config != null then [configVolumeMount] else [];

      local volumes =
        [
          storageVolume,
          datasourcesVolume,
          dashboardsVolume,
        ] +
        [
          local dashboardName = 'grafana-dashboard-' + std.strReplace(name, '.json', '');
          volume.withName(dashboardName) +
          volume.mixin.configMap.withName(dashboardName)
          for name in std.objectFields($._config.grafana.dashboards)
        ] +
        if $._config.grafana.config != null then [configVolume] else [];

      local c =
        container.new('grafana', $._config.imageRepos.grafana + ':' + $._config.versions.grafana) +
        (if std.length($._config.grafana.plugins) == 0 then {} else container.withEnv([env.new('GF_INSTALL_PLUGINS', std.join(',', $._config.grafana.plugins))])) +
        container.withVolumeMounts(volumeMounts) +
        container.withPorts(containerPort.newNamed('http', targetPort)) +
        container.mixin.resources.withRequests({ cpu: '100m', memory: '100Mi' }) +
        container.mixin.resources.withLimits({ cpu: '200m', memory: '200Mi' });

      deployment.new('grafana', 1, c, podLabels) +
      deployment.mixin.metadata.withNamespace($._config.namespace) +
      deployment.mixin.metadata.withLabels(podLabels) +
      deployment.mixin.spec.selector.withMatchLabels(podLabels) +
      deployment.mixin.spec.template.spec.withVolumes(volumes) +
      deployment.mixin.spec.template.spec.securityContext.withRunAsNonRoot(true) +
      deployment.mixin.spec.template.spec.securityContext.withRunAsUser(65534) +
      deployment.mixin.spec.template.spec.withServiceAccountName('grafana'),
  },
}
