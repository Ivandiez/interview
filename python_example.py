from os import getenv
from sys import platform
from subprocess import check_output
from json import loads
from logging import getLogger, INFO, Formatter, FileHandler, StreamHandler, Logger
from argparse import ArgumentParser
from slack_sdk.webhook.client import WebhookClient
from dotenv import load_dotenv

load_dotenv()  # take environment variables from .env.

DEFAULT_HEADERS = {'Accept': 'application/json'}


def parse_arguments():
    """
    Function for parse arguments from command line
    :return: input arguments
    """
    parser = ArgumentParser(prog='Check filters in Istio')
    parser.add_argument('--environment', type=str, help='Environment')
    parser.add_argument('--tenant', type=str, help='Tenant')
    args = parser.parse_args()

    return args


def configure_logger(task_dir: str, environment: str, tenant: str) -> Logger:
    """
    Function for logs formatting
    :param task_dir: Task dir where script locates
    :param environment: Environment
    :param tenant: Tenant
    :return: logger object
    """
    logger = getLogger("CheckIstioFilters")
    logger.setLevel(INFO)
    formatter = Formatter(fmt="%(asctime)s|%(name)s|Level:%(levelname)s|Message: %(message)s",
                          datefmt="%Y-%m-%dT%H:%M:%S")

    # In Linux we need to use forward slash (in Windows - double backslash)
    if platform == "linux":
        file_handler = FileHandler(f"{task_dir}/logs/{environment.lower()}-{tenant.lower()}.log",
                                   encoding='utf-8')
    else:
        file_handler = FileHandler(f"{task_dir}\\logs\\{environment.lower()}-{tenant.lower()}.log",
                                   encoding='utf-8')
    file_handler.setLevel(INFO)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    stream_handler = StreamHandler()
    stream_handler.setLevel(INFO)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    return logger


def send_slack_notification(slack_client: WebhookClient, slack_channel: str, environment: str,
                            tenant: str, filters: [], logger: Logger) -> None:
    """
    Function to send notifications to Slack
    :param slack_client: client for connection to Slack Webhook
    :param slack_channel: Slack Channel
    :param environment: Environment
    :param tenant: Tenant
    :param filters: list of not found filters
    :param logger: logger object
    :return:
    """
    filters_list = ('*\n*'.join(filters))
    slack_body = {
        "channel": slack_channel,
        "username": f"Istio Filters Checker",
        "text": f"<!channel> Couldn't find filter(s) in the {environment.upper()}-{tenant.upper()} cluster:\n*{filters_list}*"
                f"\nCheck cluster manually",
        "icon_emoji": ":fire:"
    }
    slack_client.send_dict(slack_body)
    logger.error(f"Slack alert was sent")


def get_listener(istio_binary: str, proxy_port: str, kube_config: str) -> str:
    """
    Function for get Listener from Istio cluster
    :param istio_binary: istioctl executable
    :param proxy_port: Proxy port number
    :param kube_config: path to kubeconfig file
    :return: listener
    """
    istio_proxy_status = check_output([istio_binary, "proxy-status", "-c", kube_config]).decode('utf-8')
    istio_proxy = istio_proxy_status.split('\n')[1].split(' ')[0]

    listener = check_output([istio_binary, "proxy-config", "listeners", istio_proxy,
                             "--port", proxy_port, "-c", kube_config, "-o", "json"]).decode('utf-8')
    return listener


def get_filters_from_cluster(listener: str) -> []:
    """
    Function for get filters from cluster
    :param listener: listener
    :return: list of filters from cluster
    """
    filters_in_cluster = list()
    for filter_chains in loads(listener)[0]['filterChains']:
        for filter_chain in filter_chains['filters']:
            for http_filter in filter_chain['typedConfig']['httpFilters']:
                filters_in_cluster.append(http_filter['name'])
    return filters_in_cluster


def check_filters_presence(filters_in_cluster: list, searched_filters: list,
                           slack_client: WebhookClient, slack_channel: str,
                           environment: str, tenant: str, logger: Logger) -> None:
    """
    Function for check filters presence in the Cluster
    :param filters_in_cluster: list of filters from cluster
    :param searched_filters: list of filters that we want to see
    :param slack_client: Slack Client for send alerts to Slack
    :param slack_channel: Slack Channel
    :param environment: Environment
    :param tenant: Tenant
    :param logger: Logger
    :return: None
    """
    not_found_filters = []
    for search_filter in searched_filters:
        if search_filter in filters_in_cluster:
            logger.info(f"Successfully found filter {search_filter} in the cluster")
        else:
            logger.error(f"Cannot find filter {search_filter} in the cluster")
            not_found_filters.append(search_filter)

    if not_found_filters:
        send_slack_notification(slack_client, slack_channel, environment, tenant,
                                not_found_filters, logger)


def main():
    args = parse_arguments()
    task_dir = getenv("TASK_DIR")
    slack_uri = getenv("SLACK_URI")
    slack_channel = getenv("SLACK_CHANNEL")
    kube_config = getenv(f"{args.environment.upper()}_{args.tenant.upper()}_K8S_CONFIG_FILE")
    proxy_port = getenv("PROXY_PORT")
    istio_binary = getenv("ISTIOCTL_EXE")
    searched_filters = getenv("SEARCHED_FILTERS").split(',')
    logger = configure_logger(task_dir, args.environment, args.tenant)
    logger.info("Script started!")

    slack_client = WebhookClient(slack_uri, default_headers=DEFAULT_HEADERS)

    listener = get_listener(istio_binary, proxy_port, kube_config)
    filters_in_cluster = get_filters_from_cluster(listener)
    check_filters_presence(filters_in_cluster, searched_filters, slack_client,
                           slack_channel, args.environment, args.tenant, logger)

    logger.info("Script finished")


if __name__ == '__main__':
    main()
